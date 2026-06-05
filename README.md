# Модель кластеризации на PySpark + Scala Data Mart

## Описание работы

В рамках работы был использован датасет OpenFoodFacts, содержащий информацию о пищевой ценности продуктов. На основе числовых признаков продуктов была реализована модель кластеризации, позволяющая разбить продукты на группы со схожими характеристиками.

Для организации работы с данными была разработана **Scala-витрина данных (data mart)**, которая берёт на себя всё взаимодействие с Qdrant и предобработку данных. Python-модель работает только с Parquet-файлами и не обращается к хранилищу напрямую.

---

## Используемый стек технологий

- Python 3.11
- PySpark
- Apache Spark
- Scala 2.12 + sbt
- Qdrant (векторная БД)
- OkHttp (HTTP-клиент для Qdrant REST API)
- Pydantic
- DVC
- DagsHub S3 Storage
- Git

---

## Архитектура

```
CSV-файл
   │
   ▼
[Data Mart: upload]          ← Scala, spark-submit
   │  читает CSV, пишет сырые данные в Qdrant
   ▼
Qdrant (products_raw)
   │
   ▼
[Data Mart: preprocess]      ← Scala, spark-submit
   │  читает из Qdrant, очищает данные, пишет Parquet
   ▼
preprocessed.parquet
   │
   ▼
[Clustering Pipeline]        ← Python / PySpark
   │  читает Parquet, обучает K-Means, пишет predictions.parquet
   ▼
predictions.parquet
   │
   ▼
[Data Mart: write-results]   ← Scala, spark-submit
   │  читает Parquet, пишет кластеризованные данные в Qdrant
   ▼
Qdrant (products_clustered)
```

Каждый шаг — отдельный Spark-контекст. Data mart запускается через `spark-submit` как subprocess из `main.py`, что гарантирует полную изоляцию JVM-сессий.

---

## Структура проекта

```
bd-lab-7/
│
├── data-mart/                       # Scala data mart (fat JAR)
│   ├── build.sbt
│   ├── project/
│   │   ├── build.properties
│   │   └── plugins.sbt
│   └── src/main/
│       ├── resources/
│       │   └── application.conf     # конфиг витрины (HOCON)
│       └── scala/com/datamart/
│           ├── DataMartApp.scala    # точка входа, роутинг режимов
│           ├── config/
│           │   └── DataMartConfig.scala
│           ├── preprocessing/
│           │   └── DataPreprocessor.scala
│           ├── reader/
│           │   ├── CsvReader.scala
│           │   └── QdrantReader.scala
│           └── writer/
│               └── QdrantWriter.scala
│
├── data/
│   ├── raw/                         # исходный CSV (не в git)
│   └── processed/                   # parquet-файлы (не в git)
│
├── src/
│   ├── config/
│   │   └── config.py
│   ├── features/
│   │   └── builder.py
│   ├── models/
│   │   └── kmeans_model.py
│   ├── evaluation/
│   │   └── evaluator.py
│   ├── pipeline/
│   │   └── clustering_pipeline.py
│   └── utils/
│       ├── logger.py
│       └── spark_manager.py
│
├── main.py
├── requirements.txt
└── README.md
```

---

## Витрина данных (Data Mart)

Витрина написана на Scala и собирается в fat JAR с помощью `sbt assembly`. Запускается через `spark-submit` с тремя режимами:

| Режим | Что делает |
|---|---|
| `upload` | Читает CSV, загружает сырые данные в Qdrant (`products_raw`) |
| `preprocess` | Читает из Qdrant, выполняет предобработку, сохраняет `preprocessed.parquet` |
| `write-results` | Читает `predictions.parquet`, загружает кластеризованные данные в Qdrant (`products_clustered`) |

### Предобработка в витрине

- Удаление пропусков
- Удаление отрицательных значений
- Удаление базовых выбросов (> 10σ)
- Удаление выбросов по персентилям (1–99%)
- Ограничение выборки
- Добавление поля `energy_tier` (low / medium / high) — структурный признак витрины

### Конфигурация Spark (витрина)

Витрина намеренно ограничена в ресурсах, чтобы не конкурировать с Python-моделью:

- `master = local[2]` — не более 2 ядер
- `spark.driver.memory = 2g`
- `spark.executor.memory = 1g`
- `spark.executor.cores = 1`
- `spark.cores.max = 2`

Параметры переопределяются через `application.conf` (HOCON).

### Взаимодействие с Qdrant

Витрина обращается к Qdrant напрямую через REST API (OkHttp) — официального Java/Scala SDK у Qdrant нет. Реализованы только нужные операции: scroll, upsert, create/delete collection.

---

## Датасет

Использовался датасет OpenFoodFacts:

https://world.openfoodfacts.org/data

Полный датасет имеет большой размер (более 13 ГБ в архиве), поэтому была выполнена предварительная обработка данных и ограничение выборки в соответствии с ресурсами локального компьютера.

Для кластеризации использовались следующие признаки:

- `energy_100g`
- `fat_100g`
- `carbohydrates_100g`
- `sugars_100g`
- `proteins_100g`

---

## Этапы pipeline

### 1. Загрузка данных (Data Mart: upload)
Чтение CSV через Spark, запись сырых данных в Qdrant (`products_raw`).

### 2. Предобработка данных (Data Mart: preprocess)
Чтение из Qdrant, очистка данных, сохранение в `preprocessed.parquet`.

### 3. Построение признаков (Python)
- VectorAssembler
- StandardScaler

### 4. Обучение модели (Python)
Алгоритм K-Means, параметры:
- k = 5
- seed = 51

### 5. Оценка качества (Python)
Метрика Silhouette Score.

Итоговый результат: **Silhouette Score = 0.7189**

Также выводились:
- размеры кластеров
- центры кластеров

### 6. Сохранение результатов (Data Mart: write-results)
Чтение `predictions.parquet`, загрузка кластеризованных данных в Qdrant (`products_clustered`) с полем `cluster` в payload.

---

## Настройка Spark (Python-модель)

- `master = local[*]`
- `spark.driver.memory = 4g`
- `spark.executor.memory = 4g`
- `spark.sql.shuffle.partitions = 8`
- `spark.serializer = KryoSerializer`
- `spark.sql.adaptive.enabled = true`

---

## Запуск проекта

Установка зависимостей:

```bash
pip install -r requirements.txt
```

Сборка JAR (выполняется автоматически при первом запуске, если JAR отсутствует):

```bash
cd data-mart && sbt assembly
```

Запуск:

```bash
python -m main
```

При первом запуске `main.py` автоматически соберёт JAR, если он ещё не существует.

---

## Версионирование данных

Для хранения больших файлов использовался DVC.

Хранились:
- обработанные данные
- обученная модель

В качестве удаленного хранилища использовался DagsHub S3 Storage.

---

## Результат работы

В ходе лабораторной работы было разработано Spark-приложение для кластеризации продуктовых данных с архитектурой витрины данных.

Была реализована:
- Scala data mart с тремя режимами работы (upload / preprocess / write-results)
- полная изоляция Qdrant I/O в витрине (Python не обращается к Qdrant напрямую)
- передача данных между Scala и Python через Parquet
- модульная Python-архитектура для кластеризации
- обучение модели K-Means и оценка качества

Полученные кластеры позволяют выделить группы продуктов с похожими характеристиками пищевой ценности.
