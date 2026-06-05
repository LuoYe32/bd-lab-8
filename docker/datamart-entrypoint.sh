#!/bin/bash
set -e

MODE=${1:-preprocess}

exec /opt/spark/bin/spark-submit \
  --master "k8s://https://kubernetes.default.svc" \
  --deploy-mode client \
  \
  --conf "spark.kubernetes.container.image=bd-lab-8/datamart:latest" \
  --conf "spark.kubernetes.container.image.pullPolicy=Never" \
  --conf "spark.kubernetes.namespace=bd-lab-8" \
  --conf "spark.kubernetes.authenticate.driver.serviceAccountName=spark-sa" \
  \
  --conf "spark.executor.instances=2" \
  --conf "spark.driver.memory=512m" \
  --conf "spark.executor.memory=512m" \
  --conf "spark.executor.cores=1" \
  \
  --conf "spark.kubernetes.executor.volumes.persistentVolumeClaim.raw-data.mount.path=/data/raw" \
  --conf "spark.kubernetes.executor.volumes.persistentVolumeClaim.raw-data.mount.readOnly=true" \
  --conf "spark.kubernetes.executor.volumes.persistentVolumeClaim.raw-data.options.claimName=raw-data-pvc" \
  \
  --conf "spark.kubernetes.executor.volumes.persistentVolumeClaim.processed-data.mount.path=/data/processed" \
  --conf "spark.kubernetes.executor.volumes.persistentVolumeClaim.processed-data.options.claimName=processed-data-pvc" \
  \
  --class com.datamart.DataMartApp \
  "local:///opt/app/data-mart-assembly.jar" \
  "${MODE}"
