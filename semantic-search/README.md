# Semantic search vertical slice

This directory contains the implemented Milestone 1 local development stack: schema contracts, embedding service, semantic indexer, query API, and evaluation assets.

## Indexer dependencies

`indexer/pyproject.toml` declares the direct dependencies; `indexer/requirements.txt` is the
hash-pinned runtime lock, including transitive packages. The container image installs only the lock
(`pip install --require-hashes`), and Trivy scans it in CI, so the scan covers exactly what ships.
After changing dependencies in `pyproject.toml`, regenerate the lock with Python 3.12 on Linux
(the image platform) and commit both files:

```bash
make lock-indexer
```

The image build runs `pip check` and fails if the lock no longer satisfies `pyproject.toml`.
