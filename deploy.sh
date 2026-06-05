#!/bin/bash
set -e

NS=bd-lab-8
QDRANT_API_KEY=${QDRANT_API_KEY:-local-dev-key}

echo " Kubernetes deploy"

echo ""
echo ">>> [1/10] Namespace"
kubectl apply -f k8s/00-namespace.yaml

echo ""
echo ">>> [2/10] Bootstrap secret for Vault init"
kubectl create secret generic qdrant-bootstrap-secret \
  -n $NS \
  --from-literal=QDRANT_API_KEY="${QDRANT_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo ">>> [3/10] Vault sync RBAC"
kubectl apply -f k8s/vault/secret-sync-rbac.yaml

echo ""
echo ">>> [4/10] Deploying Vault (dev mode)"
kubectl apply -f k8s/vault/serviceaccount.yaml
kubectl apply -f k8s/vault/vault-rbac.yaml
kubectl apply -f k8s/vault/deployment.yaml
kubectl apply -f k8s/vault/service.yaml
kubectl wait --for=condition=available deployment/vault -n $NS --timeout=300s

echo ""
echo ">>> [5/10] Initializing Vault (k8s auth + secrets)"
kubectl delete job vault-init -n $NS --ignore-not-found
kubectl apply -f k8s/vault/init-job.yaml
kubectl wait --for=condition=complete job/vault-init -n $NS --timeout=120s

echo ""
echo ">>> [6/10] Syncing secrets from Vault to k8s"
kubectl delete job vault-secret-sync -n $NS --ignore-not-found
kubectl apply -f k8s/vault/secret-sync-job.yaml
kubectl wait --for=condition=complete job/vault-secret-sync -n $NS --timeout=120s
echo "Secret synced:"
kubectl get secret qdrant-secret -n $NS

echo ""
echo ">>> [7/10] Setting up storage"
kubectl apply -f k8s/data/processed-pvc.yaml
kubectl apply -f k8s/qdrant/pvc.yaml
kubectl apply -f - <<'PVCEOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: raw-data-pvc
  namespace: bd-lab-8
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources:
    requests:
      storage: 500Mi
PVCEOF

echo ""
echo ">>> [8/10] Spark RBAC + ConfigMap"
kubectl apply -f k8s/spark/rbac.yaml
kubectl apply -f k8s/configmap.yaml

echo ""
echo ">>> [9/10] Deploying Qdrant"
kubectl apply -f k8s/qdrant/deployment.yaml
kubectl apply -f k8s/qdrant/service.yaml
kubectl wait --for=condition=available deployment/qdrant -n $NS --timeout=90s

echo ""
echo ">>> [10/10] Building and loading Docker images into Kind"
docker build -f Dockerfile.model -t bd-lab-8/model:latest .
docker build -f Dockerfile.datamart -t bd-lab-8/datamart:latest .
kind load docker-image bd-lab-8/model:latest --name bd-lab-8
kind load docker-image bd-lab-8/datamart:latest --name bd-lab-8

echo ""
echo ">>> [11/11] Loading data into PVC"
if [ -f "data/raw/products.csv" ]; then
  kubectl run data-loader -n $NS --restart=Never --image=ubuntu:22.04 \
    --overrides='{"spec":{"volumes":[{"name":"raw","persistentVolumeClaim":{"claimName":"raw-data-pvc"}}],"containers":[{"name":"data-loader","image":"ubuntu:22.04","command":["sleep","3600"],"volumeMounts":[{"name":"raw","mountPath":"/data/raw"}]}]}}' 2>/dev/null || true
  kubectl wait pod/data-loader -n $NS --for=condition=ready --timeout=60s
  kubectl cp data/raw/products.csv $NS/data-loader:/data/raw/products.csv
  kubectl delete pod data-loader -n $NS --ignore-not-found
  echo " Data loaded"
else
  echo " WARN: data/raw/products.csv not found — add it manually before running pipeline"
fi

echo ""
echo "Infrastructure ready! Run pipeline with:"
echo "   ./run-pipeline.sh"
