from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from jsonschema import Draft202012Validator

from semantic_indexer.models import OperationalEvent


class EventValidationError(ValueError):
  pass


class EventValidator:
  def __init__(self, schema_path: str, valid_hosts: list[str]) -> None:
    schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))
    self._validator = Draft202012Validator(schema)
    self._valid_hosts = set(valid_hosts)

  def parse(self, payload: dict[str, Any]) -> OperationalEvent:
    errors = sorted(self._validator.iter_errors(payload), key=lambda error: error.path)
    if errors:
      raise EventValidationError("; ".join(error.message for error in errors))
    event = OperationalEvent.model_validate(payload)
    for reference in event.evidence:
      parsed = urlparse(reference.url)
      if parsed.scheme not in {"http", "https"} or parsed.netloc not in self._valid_hosts:
        raise EventValidationError(f"invalid evidence URL host: {reference.url}")
    return event
