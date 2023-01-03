
apiVersion: v1
kind: Namespace
metadata:
  name: ext-dns
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: externaldns
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods"]
  verbs: ["get","watch","list"]
- apiGroups: ["extensions","networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get","watch","list"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: externaldns-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: externaldns
subjects:
- kind: ServiceAccount
  name: externaldns
  namespace: ext-dns
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: externaldns
  namespace: ext-dns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: externaldns
  namespace: ext-dns
spec:
  selector:
    matchLabels:
      app: externaldns
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: externaldns
    spec:
      serviceAccountName: externaldns
      containers:
      - name: externaldns
        image: k8s.gcr.io/external-dns/external-dns:v0.13.1
        args:
        - --source=service
        - --source=ingress
        - --provider=azure-private-dns
        - --azure-subscription-id=SUBSCRIPTION_ID
        volumeMounts:
        - name: azure-config-file
          mountPath: /etc/kubernetes
          readOnly: true
      volumes:
      - name: azure-config-file
        secret:
          secretName: azure-config-file
