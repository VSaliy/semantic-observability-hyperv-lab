# Version management

## Rules

- Pin every container image, chart, and major tool version in `/versions.yaml`.
- Never use floating `latest` tags.
- Update Docker Compose, Maven, Python, Helm, Terraform, and documentation in the same change.

## Update procedure

1. Change `/versions.yaml`.
2. Update any image tags and dependency files that consume the version.
3. Run `make validate` and affected tests.
4. Document compatibility impacts in the matrix below.

## Compatibility matrix

| Layer | Source of truth | Current pin |
| --- | --- | --- |
| Java runtime | `/versions.yaml` | 21 |
| Spring Boot | `/versions.yaml` and `semantic-search/query-api/pom.xml` | 3.3.2 |
| Python runtime | `/versions.yaml` and `semantic-search/indexer/pyproject.toml` | 3.12 |
| OpenSearch | `/versions.yaml` and `docker-compose.dev.yml` | 2.17.1 |
| Kafka | `/versions.yaml` and `docker-compose.dev.yml` | 7.7.1 |
