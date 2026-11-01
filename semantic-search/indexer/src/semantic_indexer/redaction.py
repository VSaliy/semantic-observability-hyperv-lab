from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit, urlunsplit

SENSITIVE_MARKERS = ("password", "secret", "token", "authorization", "connection", "cookie")
SENSITIVE_QUERY_KEYS = frozenset({
  "api_key",
  "apikey",
  "key",
  "sig",
  "signature",
  "access_token",
  "refresh_token",
  "id_token",
  "session",
  "session_id",
})
REDACTED = "[REDACTED]"
URL_REDACTED = "REDACTED"

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
    r"(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|authorization)\b\s*[=:]\s*[^\s,;&]+"
  ),
)


def redact_text(text: str) -> str:
  for pattern in VALUE_PATTERNS:
    text = pattern.sub(REDACTED, text)
  return text


def redact_evidence_url(url: str) -> str:
  """Redact sensitive query parameters and secret patterns in an evidence URL.

  Uses an RFC 3986-safe token (`REDACTED`) so the resulting URL remains parseable by strict URI
  validators such as `java.net.URI`.
  """
  try:
    parsed = urlsplit(url)
  except ValueError:
    return redact_text(url).replace(REDACTED, URL_REDACTED)
  if not parsed.scheme or not parsed.netloc:
    return redact_text(url).replace(REDACTED, URL_REDACTED)

  path = redact_text(parsed.path).replace(REDACTED, URL_REDACTED)
  fragment = redact_text(parsed.fragment).replace(REDACTED, URL_REDACTED)
  if parsed.query:
    redacted_pairs: list[str] = []
    for pair in parsed.query.split("&"):
      if "=" in pair:
        param_key, param_val = pair.split("=", 1)
        if is_sensitive_key(param_key) or param_key.lower() in SENSITIVE_QUERY_KEYS:
          redacted_pairs.append(f"{param_key}={URL_REDACTED}")
        else:
          clean_val = redact_text(param_val).replace(REDACTED, URL_REDACTED)
          redacted_pairs.append(f"{param_key}={clean_val}")
      else:
        redacted_pairs.append(redact_text(pair).replace(REDACTED, URL_REDACTED))
    query = "&".join(redacted_pairs)
  else:
    query = ""
  return urlunsplit((parsed.scheme, parsed.netloc, path, query, fragment))


def redact_value(value: Any) -> Any:
  if isinstance(value, dict):
    return {
      key: (REDACTED if is_sensitive_key(key) else redact_value(item))
      for key, item in value.items()
    }
  if isinstance(value, list):
    return [redact_value(item) for item in value]
  if isinstance(value, str):
    if value.startswith(("http://", "https://")):
      return redact_evidence_url(value)
    return redact_text(value)
  return value


def is_sensitive_key(key: str) -> bool:
  lowered = key.lower()
  return any(marker in lowered for marker in SENSITIVE_MARKERS)
