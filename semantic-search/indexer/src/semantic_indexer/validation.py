from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from jsonschema import Draft202012Validator
from pydantic import ValidationError

from semantic_indexer.models import OperationalEvent
from semantic_indexer.redaction import redact_evidence_url, redact_text


class EventValidationError(ValueError):
  pass


def _format_schema_error(error: Any) -> str:
  location = ".".join(str(part) for part in error.path) or "<root>"
  if error.validator == "required":
    return f"{location}: {redact_text(error.message)}"
  return f"{location}: failed {error.validator} validation"


class EventValidator:
  def __init__(
    self,
    schema_path: str,
    valid_hosts: list[str],
    tenant_valid_hosts: dict[str, list[str]] | None = None,
  ) -> None:
    schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))
    self._validator = Draft202012Validator(schema)
    self._valid_hosts = set(valid_hosts)
    self._tenant_valid_hosts = {
      tenant: set(hosts) for tenant, hosts in (tenant_valid_hosts or {}).items()
    }

  def parse(self, payload: dict[str, Any]) -> OperationalEvent:
    try:
      event = OperationalEvent.model_validate(payload)
    except ValidationError as exc:
      messages = [
        f"{'.'.join(str(part) for part in err.get('loc', ()))}: {err.get('msg', 'invalid value')}"
        for err in exc.errors(include_input=False, include_url=False)
      ]
      raise EventValidationError("; ".join(messages) or "invalid event payload") from exc
    errors = sorted(self._validator.iter_errors(payload), key=lambda error: list(error.path))
    if errors:
      raise EventValidationError("; ".join(_format_schema_error(error) for error in errors))
    allowed_hosts = self._tenant_valid_hosts.get(event.tenantId, self._valid_hosts)
    for reference in event.evidence:
      parsed = urlparse(reference.url)
      if parsed.scheme not in {"http", "https"} or parsed.netloc not in allowed_hosts:
        raise EventValidationError(
          f"invalid evidence URL host: {redact_evidence_url(reference.url)}"
        )
    return event
