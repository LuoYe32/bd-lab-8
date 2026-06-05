.PHONY: build-datamart build-model build-all run clean

build-datamart:
	docker build -f Dockerfile.datamart -t bd-lab-8/datamart:latest .
	./import-image.sh bd-lab-8/datamart:latest

build-model:
	docker build -f Dockerfile.model -t bd-lab-8/model:latest .
	./import-image.sh bd-lab-8/model:latest

build-all: build-datamart build-model

run:
	./run-pipeline.sh

all: build-all run

clean:
	kubectl delete jobs -n bd-lab-8 \
	  datamart-upload datamart-preprocess datamart-write-results clustering-model \
	  --ignore-not-found
	kubectl delete pods -n bd-lab-8 -l spark-role=executor --ignore-not-found 2>/dev/null || true

