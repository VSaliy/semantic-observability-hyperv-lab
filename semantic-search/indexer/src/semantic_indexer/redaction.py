from __future__ import annotations

import re
from typing import Any

SENSITIVE_MARKERS = ("password", "secret", "token", "authorization", "connection", "cookie")
REDACTED = "[REDACTED]"

# Value patterns for secrets and personal data that appear in free text or under innocuous keys.
VALUE_PATTERNS = (
  re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)", re.DOTALL
  ),
  re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
  re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", re.IGNORECASE),
  re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
  re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b"),
  re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\b"),
  re.compile(
    r"(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|authorization)\b\s*[=:]\s*[^\s,;]+"
  ),
)


def redact_text(text: str) -> str:
  for pattern in VALUE_PATTERNS:
    text = pattern.sub(REDACTED, text)
  return text


def redact_value(value: Any) -> Any:
  if isinstance(value, dict):
    return {
      key: (REDACTED if is_sensitive_key(key) else redact_value(item))
      for key, item in value.items()
    }
  if isinstance(value, list):
    return [redact_value(item) for item in value]
  if isinstance(value, str):
    return redact_text(value)
  return value


def is_sensitive_key(key: str) -> bool:
  lowered = key.lower()
  return any(marker in lowered for marker in SENSITIVE_MARKERS)
