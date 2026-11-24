#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator

schema_path = Path("semantic-search/schemas/operational-event.schema.json")
fixture_path = Path("semantic-search/indexer/fixtures/seed-events.jsonl")
schema = json.loads(schema_path.read_text(encoding="utf-8"))
validator = Draft202012Validator(schema)
for index, line in enumerate(fixture_path.read_text(encoding="utf-8").splitlines(), start=1):
  payload = json.loads(line)
  errors = sorted(validator.iter_errors(payload), key=lambda error: error.path)
  if errors:
    raise SystemExit(f"fixture {index} invalid: {'; '.join(error.message for error in errors)}")
print("validated seed event fixtures")
