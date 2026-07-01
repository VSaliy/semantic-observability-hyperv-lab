from __future__ import annotations

from typing import Any

SENSITIVE_MARKERS = ("password", "secret", "token", "authorization", "connection", "cookie")
REDACTED = "[REDACTED]"


def redact_value(value: Any) -> Any:
  if isinstance(value, dict):
    return {key: (REDACTED if is_sensitive_key(key) else redact_value(item)) for key, item in value.items()}
  if isinstance(value, list):
    return [redact_value(item) for item in value]
  return value


def is_sensitive_key(key: str) -> bool:
  lowered = key.lower()
  return any(marker in lowered for marker in SENSITIVE_MARKERS)
