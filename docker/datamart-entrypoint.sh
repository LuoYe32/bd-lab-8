#!/bin/bash
set -e

MODE=${1:-preprocess}

exec /opt/spark/bin/spark-submit \
  --master "local[2]" \
  \
  --conf "spark.driver.memory=1g" \
  --conf "spark.driver.maxResultSize=256m" \
  \
  --class com.datamart.DataMartApp \
  "local:///opt/app/data-mart-assembly.jar" \
  "${MODE}"
