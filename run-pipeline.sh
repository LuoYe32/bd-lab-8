#!/bin/bash
set -e
cd "$(dirname "$0")"

echo " BD Lab 8 Pipeline "

echo "[1/5] Checking cluster..."
kubectl get nodes --request-timeout=10s > /dev/null || { echo "ERROR: Kubernetes not running. Enable in Docker Desktop: Settings → Kubernetes → Enable"; exit 1; }
echo "      OK"

echo "[2/5] Checking Vault secrets..."
if ! kubectl get secret qdrant-secret -n bd-lab-8 &>/dev/null; then
  echo "      Re-initializing Vault..."
  kubectl delete job vault-init vault-secret-sync -n bd-lab-8 --ignore-not-found 2>/dev/null
  kubectl apply -f k8s/vault/init-job.yaml
  until kubectl get job vault-init -n bd-lab-8 --no-headers 2>/dev/null | grep -q "1/1"; do sleep 5; done
  kubectl apply -f k8s/vault/secret-sync-job.yaml
  until kubectl get job vault-secret-sync -n bd-lab-8 --no-headers 2>/dev/null | grep -q "1/1"; do sleep 5; done
  echo "      Done."
else
  echo "      OK"
fi

run_job() {
  local name=$1 yaml=$2
  echo ""
  echo ">>> $name"
  kubectl delete job "$name" -n bd-lab-8 --ignore-not-found 2>/dev/null
  kubectl delete pods -n bd-lab-8 -l spark-role=executor --ignore-not-found 2>/dev/null
  kubectl apply -f "$yaml"
  until kubectl get job "$name" -n bd-lab-8 --no-headers 2>/dev/null | grep -q "1/1"; do
    if kubectl get job "$name" -n bd-lab-8 --no-headers 2>/dev/null | grep -qE "0/1.*BackoffLimitExceeded|Failed"; then
      echo "ERROR: job $name failed"; kubectl logs -n bd-lab-8 -l "job-name=$name" --tail=20 2>/dev/null; exit 1
    fi
    sleep 5
  done
  kubectl logs -n bd-lab-8 -l "job-name=$name" --tail=4 2>/dev/null | grep -vE "^26/" || true
  echo "    DONE ✓"
}

echo "[3/5] Running pipeline..."
run_job datamart-upload        k8s/jobs/datamart-upload.yaml
run_job datamart-preprocess    k8s/jobs/datamart-preprocess.yaml
run_job clustering-model       k8s/jobs/model.yaml
run_job datamart-write-results k8s/jobs/datamart-write-results.yaml

echo ""
echo "[4/5] Jobs:"
kubectl get jobs -n bd-lab-8 | grep -E "datamart|clustering"

echo ""
echo "[5/5] Qdrant collections:"
kubectl port-forward -n bd-lab-8 svc/qdrant 6333:6333 &>/dev/null & PF=$!
sleep 2
curl -s http://localhost:6333/collections -H "api-key: super-secret-qdrant-key-lab8" 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(' -', c['name']) for c in d['result']['collections']]"
kill $PF 2>/dev/null

echo ""
echo " Done! Dashboard: http://localhost:6333/dashboard "
