#!/bin/bash
# import-image.sh <image-name>
# Импортирует Docker-образ в k8s.io namespace containerd (Docker Desktop)
# Пример: ./import-image.sh bd-lab-8/datamart:latest

set -e

IMAGE="${1:?Usage: ./import-image.sh <image-name>}"
TAR="/tmp/k8s-import-$(echo $IMAGE | tr '/: ' '---').tar"
POD="ctr-importer"

echo "→ Saving $IMAGE..."
docker save "$IMAGE" -o "$TAR"

echo "→ Starting importer pod..."
kubectl delete pod $POD --ignore-not-found 2>/dev/null
kubectl run $POD --restart=Never --image=alpine \
  --overrides='{
    "spec":{
      "hostPID":true,
      "tolerations":[{"operator":"Exists"}],
      "volumes":[{"name":"ctr","hostPath":{"path":"/run/containerd/containerd.sock"}}],
      "containers":[{
        "name":"ctr",
        "image":"alpine",
        "command":["sh","-c","apk add --no-cache containerd-ctr -q && sleep 600"],
        "volumeMounts":[{"name":"ctr","mountPath":"/run/containerd/containerd.sock"}],
        "securityContext":{"privileged":true}
      }]
    }
  }'
kubectl wait pod/$POD --for=condition=ready --timeout=60s

echo "→ Copying tar to pod..."
kubectl cp "$TAR" "$POD:/image.tar"

echo "→ Importing into k8s.io namespace..."
kubectl exec $POD -- sh -c "ctr -a /run/containerd/containerd.sock -n k8s.io images import /image.tar"

echo "→ Cleaning up..."
kubectl delete pod $POD --ignore-not-found 2>/dev/null
rm -f "$TAR"

echo "✓ Done: $IMAGE is now available to Kubernetes"
