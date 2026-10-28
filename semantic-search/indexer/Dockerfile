FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt pyproject.toml ./
COPY src ./src
# Install the hash-pinned lock, then the package without resolving again. pip check fails the
# build if pyproject.toml gained a dependency that requirements.txt does not provide.
RUN pip install --no-cache-dir --require-hashes -r requirements.txt \
  && pip install --no-cache-dir --no-deps . \
  && pip check
CMD ["python", "-m", "semantic_indexer.main"]
