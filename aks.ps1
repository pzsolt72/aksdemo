# variables
$SUBSCRIPTION=$env:AZURE_TECH_SUBSCRIPTION
$LOCATION='northeurope'
$AKS_RESOURCE_GROUP='rg-ne-demo-aks'
$DNS_RESOURCE_GROUP='rg-ne-demo-dns'
$AKS_NAME='aks-ne-demo-aks'
$AKS_MI_NAME='mi-ne-demo-aks'
$DNS_NAME='demoaks.com'

# set account
az account set --subscription $SUBSCRIPTION

# create .tmp dir
mkdir .tmp -Force


##############################################################
#  AKS
##############################################################

# create the AKS resource group
az group create --name $AKS_RESOURCE_GROUP --location $LOCATION
# create the AKS
az aks create -g $AKS_RESOURCE_GROUP -n $AKS_NAME `
  --enable-managed-identity `
  --node-count 1 `
  --enable-addons monitoring `
  --enable-msi-auth-for-monitoring  `
  --generate-ssh-keys 

# create the user managed identity 
az identity create --name $AKS_MI_NAME --resource-group $AKS_RESOURCE_GROUP --location $LOCATION


# user managed identity objectId (principal id)
$MI_ID=az identity show -n $AKS_MI_NAME -g $AKS_RESOURCE_GROUP --query principalId -o tsv
$MI_ID
# user managed identity resource id
$MI_RESOURCE_ID=az identity show -n $AKS_MI_NAME -g $AKS_RESOURCE_GROUP --query id -o tsv
$MI_RESOURCE_ID
# AKS VMSS resource group name
$AKS_VMSS_RG=az aks show -g $AKS_RESOURCE_GROUP -n $AKS_NAME --query nodeResourceGroup -o tsv
$AKS_VMSS_RG
# AKS VMSS name
$AKS_VMSS_NAME=az vmss list -g $AKS_VMSS_RG --query [0].name -o tsv
$AKS_VMSS_NAME
# AKS VNET name
$AKS_VNET=az network vnet list -g $AKS_VMSS_RG --query [0].name -o tsv
$AKS_VNET
# AKS VNET id
$AKS_VNET_ID=az network vnet list -g $AKS_VMSS_RG --query [0].id -o tsv
$AKS_VNET_ID

$AKS_VMSS_NSG=az network nsg list --resource-group $AKS_VMSS_RG --query [0].name -o tsv
$AKS_VMSS_NSG

# Assign user managed identity to the VMSS
az vmss identity assign -g $AKS_VMSS_RG -n $AKS_VMSS_NAME --identities $MI_RESOURCE_ID

# create the private DNS zone in a separate resource group
az group create --name $DNS_RESOURCE_GROUP --location $LOCATION
az network private-dns zone create -g $DNS_RESOURCE_GROUP -n $DNS_NAME
az network private-dns link vnet create -g $DNS_RESOURCE_GROUP -n link-$AKS_VNET -z $DNS_NAME -v $AKS_VNET_ID -e False

$DNS_RESOURCE_GROUP_ID=az group show -n $DNS_RESOURCE_GROUP --query id -o tsv

# assign Private DNS Zone Contributor role to mi on scope of the DNS resource group
az role assignment create `
    --assignee-object-id $MI_ID `
    --assignee-principal-type ServicePrincipal `
    --role 	b12aa53e-6015-4669-85d0-8515ebb3ae7f `
    --scope $DNS_RESOURCE_GROUP_ID

# add 22 port to the AKS subnet NSG ( access to the tester VM ) 
az network nsg rule create -g $AKS_VMSS_RG --nsg-name $AKS_VMSS_NSG -n AllowSsh22 `
  --priority 100 `
  --destination-port-ranges 22 `
  --destination-address-prefixes '*' `
  --source-port-ranges '*' `
  --source-address-prefixes '*'    

# create tester VM
az vm create `
   --resource-group $AKS_VMSS_RG `
   --name aksdemotester `
   --image UbuntuLTS  `
   --admin-username azureadmn `
   --admin-password Azureadmn1234. `
   --vnet-name $AKS_VNET `
   --subnet aks-subnet

 
# set up the AKS access ( you need kubectl and helm to be installed! )
az account set --subscription $SUBSCRIPTION
az aks get-credentials --resource-group $AKS_RESOURCE_GROUP --name $AKS_NAME --overwrite-existing


##############################################################
#  Ingress controller
##############################################################

$NAMESPACE='ingress-basic'

# ingress helm repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# install the ingress controller with internap IP access
helm install ingress-nginx ingress-nginx/ingress-nginx `
  --create-namespace `
  --namespace $NAMESPACE `
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz `
  -f internal-ingress.yml




##############################################################
#  External DNS
##############################################################

# get client and tenant ids
$CLIENT_ID=az identity show -n $AKS_MI_NAME -g $AKS_RESOURCE_GROUP --query clientId -o tsv
$TENANT_ID=az identity show -n $AKS_MI_NAME -g $AKS_RESOURCE_GROUP --query tenantId -o tsv
$CLIENT_ID
$TENANT_ID

# Generate the azure.json file for external-dns ( stored as secret )
(Get-Content -path .\azure.json.tpl  -Raw) `
-replace 'SUBSCRIPTION_ID',$SUBSCRIPTION `
-replace 'TENANT_ID', $TENANT_ID `
-replace 'DNS_RESOURCE_GROUP', $DNS_RESOURCE_GROUP `
-replace 'CLIENT_ID', $CLIENT_ID | Set-Content -Path './.tmp/azure.json'

# Generate the external-dns.yml
(Get-Content -path .\external-dns.yml.tpl  -Raw) `
-replace 'SUBSCRIPTION_ID',$SUBSCRIPTION `
 | Set-Content -Path './.tmp/external-dns.yml'

# install the external-dns component
kubectl apply -f .\.tmp\external-dns.yml
# create secret from azure.json ( containing info to access the Azure )
kubectl create secret generic azure-config-file -n ext-dns --from-file=.\.tmp\azure.json

# wait to start the external-dns
Start-Sleep -Seconds 15


##############################################################
#  Cert manager
##############################################################

# install the cert-manager with helm
helm install `
  cert-manager jetstack/cert-manager `
  --namespace cert-manager `
  --create-namespace `
  --version v1.10.1 `
  --set installCRDs=true

# Generate the cm-caissuer.yml file for cert manager CA issuer ( replaceing the base64 encoded contetnt from cert and key files )
$CACRT=[convert]::ToBase64String((Get-Content -path "ca.crt" -Encoding byte))
$CAKEY=[convert]::ToBase64String((Get-Content -path "ca.key" -Encoding byte))
(Get-Content -path .\cm-caissuer.yml.tpl  -Raw) `
-replace 'CA_CRT',$CACRT `
-replace 'CA_KEY', $CAKEY `
 | Set-Content -Path './.tmp/cm-caissuer.yml'

# deploy the issuer
kubectl apply -f .\.tmp\cm-caissuer.yml


##############################################################
#  Demo app
##############################################################

# install the test app
kubectl apply -f .\testapp.yml



##############################################################
#  Test
##############################################################

# get the pods from external dns for logs
kubectl get pods -n ext-dns
# get the pods from cert manager for logs
kubectl get pods -n cert-manager

# kubectl logs externaldns-5df4f7d4fc-sbshm -f -n ext-dns
# kubectl logs -n cert-manager -f cert-manager-7599c44747-ds767

# TEST
# ssh into the akstest VM and use curl
# curl -v -k https://demoapp.demoaks.com

# cleanup
#  az group delete --name $AKS_RESOURCE_GROUP --yes; az group delete --name $DNS_RESOURCE_GROUP --yes
#  
