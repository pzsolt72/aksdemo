$SUBSCRIPTION=$env:AZURE_TECH_SUBSCRIPTION

$AKS_RESOURCE_GROUP='rg-ne-demo-aks'

$AKS_NAME='aks-ne-demo-aks'


az extension add -n k8s-configuration
az extension add -n k8s-extension

az k8s-configuration flux create -g $AKS_RESOURCE_GROUP `
-c $AKS_NAME `
-n cluster-config `
-t managedClusters `
--namespace gitops-config `
--scope cluster `
-u https://github.com/pzsolt72/aksdemo `
--branch main  `
--kustomization name=infra path=./gitops/app1 prune=true 
