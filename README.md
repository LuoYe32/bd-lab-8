# Кластеризация продуктов: PySpark + Scala Data Mart на Kubernetes

## Описание

Система кластеризации продуктов OpenFoodFacts, полностью развёрнутая в Kubernetes. Пайплайн запускается как последовательность Kubernetes Jobs. Секреты хранятся в HashiCorp Vault. Данные между шагами передаются через PersistentVolumeClaim.

---

## Стек технологий

- **Оркестрация**: Kubernetes (Docker Desktop + Kind), kubectl
- **Вычисления**: Apache Spark, PySpark, Scala 2.12 + sbt
- **Хранилище**: Qdrant (векторная БД), PersistentVolumeClaim
- **Секреты**: HashiCorp Vault (dev mode) + k8s Secret sync
- **Мониторинг ресурсов**: metrics-server (`kubectl top`)
- **Версионирование данных**: DVC + DagsHub S3

---

## Архитектура

```
raw-data-pvc (products.csv)
        │
        ▼
[Job: datamart-upload]          ← Scala / spark-submit local[2]
        │  читает CSV → пишет в Qdrant (products_raw)
        ▼
Qdrant: products_raw
        │
        ▼
[Job: datamart-preprocess]      ← Scala / spark-submit local[2]
        │  читает Qdrant → очищает → пишет Parquet
        ▼
processed-data-pvc (preprocessed.parquet)
        │
        ▼
[Job: clustering-model]         ← Python / PySpark local[2]
        │  читает Parquet → K-Means → пишет predictions.parquet
        ▼
processed-data-pvc (predictions.parquet)
        │
        ▼
[Job: datamart-write-results]   ← Scala / spark-submit local[2]
        │  читает Parquet → пишет в Qdrant (products_clustered)
        ▼
Qdrant: products_clustered
```

Секреты: **Vault** → `vault-secret-sync` Job → k8s Secret `qdrant-secret` → Qdrant pod

---

## Структура проекта

```
bd-lab-8/
│
├── deploy.sh                        # полный деплой инфраструктуры
├── run-pipeline.sh                  # запуск пайплайна
├── port-forward.sh                  # проброс портов Qdrant (6333) и Vault (8200)
│
├── Dockerfile.model                 # образ PySpark-модели
├── Dockerfile.datamart              # образ Scala-витрины
├── docker/
│   └── datamart-entrypoint.sh       # spark-submit для витрины
│
├── k8s/
│   ├── 00-namespace.yaml
│   ├── configmap.yaml
│   ├── vault/
│   │   ├── deployment.yaml          # strategy: RollingUpdate
│   │   ├── service.yaml
│   │   ├── serviceaccount.yaml
│   │   ├── vault-rbac.yaml
│   │   ├── init-job.yaml            # инициализация Vault
│   │   ├── secret-sync-job.yaml     # синхронизация секрета → k8s Secret
│   │   └── secret-sync-rbac.yaml
│   ├── qdrant/
│   │   ├── deployment.yaml          # strategy: Recreate
│   │   ├── service.yaml
│   │   └── pvc.yaml
│   ├── spark/
│   │   └── rbac.yaml
│   ├── data/
│   │   └── processed-pvc.yaml
│   └── jobs/
│       ├── datamart-upload.yaml
│       ├── datamart-preprocess.yaml
│       ├── datamart-write-results.yaml
│       └── model.yaml
│
├── data-mart/                       # Scala data mart (fat JAR)
│   ├── build.sbt
│   └── src/main/scala/com/datamart/
│       ├── DataMartApp.scala
│       ├── config/DataMartConfig.scala
│       ├── preprocessing/DataPreprocessor.scala
│       ├── reader/{CsvReader,QdrantReader}.scala
│       └── writer/QdrantWriter.scala
│
├── src/                             # Python-модель
│   ├── config/config.py
│   ├── features/builder.py
│   ├── models/kmeans_model.py
│   ├── evaluation/evaluator.py
│   ├── pipeline/clustering_pipeline.py
│   └── utils/{logger,spark_manager}.py
│
├── main.py
├── requirements.txt
└── data/raw/products.csv            # DVC
```

---

## Быстрый старт

### Требования

- Docker Desktop с включённым Kubernetes (Settings → Kubernetes → Enable)
- kubectl
- Java 11+, sbt (для сборки Scala JAR)

### Деплой инфраструктуры

```bash
QDRANT_API_KEY=super-secret-qdrant-key-lab8 ./deploy.sh
```

Скрипт выполняет:
1. `docker pull` внешних образов (Vault, Qdrant, Ubuntu)
2. Создаёт namespace, RBAC, ServiceAccount'ы
3. Поднимает Vault, инициализирует (KV v2, k8s auth, политики)
4. Синхронизирует `QDRANT_API_KEY` из Vault в k8s Secret
5. Создаёт PVC, разворачивает Qdrant
6. Собирает Docker-образы, загружает в containerd кластера
7. Загружает `products.csv` в `raw-data-pvc`

### Запуск пайплайна

```bash
./run-pipeline.sh
```

### Доступ к UI

```bash
./port-forward.sh
# Qdrant: http://localhost:6333/dashboard  (api-key: super-secret-qdrant-key-lab8)
# Vault:  http://localhost:8200            (token: root)
```

### Мониторинг

```bash
kubectl top pods -n bd-lab-8
kubectl get pods -n bd-lab-8
```

---

## Инфраструктура Kubernetes

### HashiCorp Vault

- Хранит API-ключ Qdrant в KV v2 (`secret/bd-lab-8/qdrant`)
- `vault-init` Job — включает движок секретов, настраивает k8s auth
- `vault-secret-sync` Job — читает секрет из Vault, создаёт k8s Secret `qdrant-secret`
- Стратегия обновления: **RollingUpdate** (stateless)

### Qdrant

- Данные на PVC `qdrant-storage-pvc` (ReadWriteOnce)
- API-ключ монтируется из k8s Secret `qdrant-secret`
- Стратегия обновления: **Recreate** (ReadWriteOnce PVC не допускает двух подов одновременно)

### Kubernetes Jobs

Все шаги пайплайна имеют `ttlSecondsAfterFinished: 300` (автоудаление через 5 минут).

| Job | Образ | Режим Spark |
|---|---|---|
| datamart-upload | bd-lab-8/datamart | local[2] |
| datamart-preprocess | bd-lab-8/datamart | local[2] |
| clustering-model | bd-lab-8/model | local[2] |
| datamart-write-results | bd-lab-8/datamart | local[2] |

---

## Оптимизация ресурсов

Лимиты выставлены на основе замеров `kubectl top` во время выполнения пайплайна.
Формула: `limit = peak_usage / 0.75`

| Job | RAM пик | Лимит RAM | Утилизация |
|---|---|---|---|
| datamart-upload | 357 Mi | 400 Mi | 89% |
| datamart-preprocess | 334 Mi | 400 Mi | 83% |
| datamart-write-results | 269 Mi | 350 Mi | 77% |
| clustering-model | 536 Mi | 700 Mi | 76% |

---

## Витрина данных (Scala)

Три режима, запускаются через `spark-submit local[2]`:

| Режим | Действие |
|---|---|
| `upload` | CSV → Qdrant `products_raw` |
| `preprocess` | Qdrant → предобработка → `preprocessed.parquet` |
| `write-results` | `predictions.parquet` → Qdrant `products_clustered` |

Взаимодействие с Qdrant через REST API (OkHttp) — официального Java/Scala SDK нет.

Предобработка в витрине: удаление пропусков, отрицательных значений, выбросов (>10σ и по персентилям 1–99%), добавление поля `energy_tier`.

---

## Датасет

OpenFoodFacts: https://world.openfoodfacts.org/data

Признаки: `energy_100g`, `fat_100g`, `carbohydrates_100g`, `sugars_100g`, `proteins_100g`.

```bash
# Скачать через DVC
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> dvc pull data/raw/products.csv
```

---

## Результаты модели

- Алгоритм: K-Means, k=5, seed=51
- **Silhouette Score: 0.7189**
- Результаты записываются в Qdrant коллекцию `products_clustered` с полем `cluster` в payload
