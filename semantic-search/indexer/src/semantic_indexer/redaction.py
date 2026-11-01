from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit, urlunsplit

SENSITIVE_MARKERS = ("password", "secret", "token", "authorization", "connection", "cookie")
_SENSITIVE_KEY_SEGMENTS = frozenset({
  "password",
  "passwd",
  "pwd",
  "secret",
  "secrets",
  "authorization",
  "cookie",
  "cookies",
  "apikey",
  "credential",
  "credentials",
})
_TOKEN_METRIC_SEGMENTS = frozenset({
  "count",
  "counts",
  "used",
  "usage",
  "limit",
  "limits",
  "total",
  "budget",
  "rate",
})
_CONNECTION_SECRET_SEGMENTS = frozenset({"string", "url", "uri", "dsn"})
_KEY_SEGMENT_RE = re.compile(r"[A-Z]+(?=[A-Z][a-z]|\b|[^A-Za-z])|[A-Z]?[a-z]+|[0-9]+")
SENSITIVE_QUERY_KEYS = frozenset({
  "api_key",
  "apikey",
  "key",
  "sig",
  "signature",
  "token",
  "secret",
  "password",
  "passwd",
  "pwd",
  "authorization",
  "cookie",
  "connection",
  "access_token",
  "refresh_token",
  "id_token",
  "session",
  "session_id",
})
REDACTED = "[REDACTED]"
URL_REDACTED = "REDACTED"

_COMMON_PROSE_WORDS = frozenset({
  "accepted",
  "authentication",
  "authorization",
  "canceled",
  "cancelled",
  "complete",
  "completed",
  "configuration",
  "connected",
  "connecting",
  "connection",
  "connections",
  "detected",
  "disabled",
  "disconnected",
  "enabled",
  " established",
  "exceeded",
  "exhausted",
  "expected",
  "expiration",
  "expired",
  "failed",
  "forbidden",
  "inactive",
  "initiation",
  "invalid",
  "mismatch",
  "missing",
  "notfound",
  "optional",
  "override",
  "pending",
  "permission",
  "provided",
  "received",
  "refused",
  "rejected",
  "replaced",
  "required",
  "resetting",
  "resolved",
  "response",
  "restored",
  "retained",
  "retried",
  "retrying",
  "revoked",
  "rotation",
  "scheduled",
  "selected",
  "skipped",
  "starting",
  "succeeded",
  "supported",
  "terminated",
  "throttled",
  "timedout",
  "timeout",
  "timeouts",
  "transient",
  "unauthorized",
  "unavailable",
  "undefined",
  "unexpected",
  "unknown",
  "unsupported",
  "unverified",
  "updating",
  "validated",
  "validating",
  "validation",
  "verified",
  "verifying",
  "verification",
})

# Value patterns for secrets and personal data that appear in free text or under innocuous keys.
VALUE_PATTERNS = (
  re.compile(
    r"-----BEGIN [A-Z ]{0,32}PRIVATE KEY-----[\s\S]{0,16384}?"
    r"(?:-----END [A-Z ]{0,32}PRIVATE KEY-----|$)"
  ),
  re.compile(r"\beyJ[A-Za-z0-9_-]{8,2048}\.[A-Za-z0-9_-]{8,2048}\.[A-Za-z0-9_-]{8,2048}\b"),
  re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,2048}", re.IGNORECASE),
  re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
  re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{30,255})\b"),
  re.compile(
    r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}"
    r"@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,10}\.[A-Za-z]{2,24}\b"
  ),
)

_ASSIGNMENT_PATTERN = re.compile(
  r"(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|authorization)\b"
  r"\s*([=:])\s*([^\s,;&#]{8,512})"
)
_URL_USERINFO_PATTERN = re.compile(r"(https?://)[^\s/@\"'<>]+@")


def _looks_like_secret_value(separator: str, raw_value: str) -> bool:
  cleaned = raw_value.rstrip(".,;:)]}'\"")
  if len(cleaned) < 8:
    return False
  if cleaned.lower() in _COMMON_PROSE_WORDS:
    return False
  if any(ch.isdigit() for ch in cleaned):
    return True
  if not cleaned.isalpha():
    return True
  if any(ch.isupper() for ch in cleaned[1:]):
    return True
  return separator == "="


def _redact_assignment(match: re.Match[str]) -> str:
  separator = match.group(1)
  candidate = match.group(2)
  if _looks_like_secret_value(separator, candidate):
    return REDACTED
  return match.group(0)


def redact_text(text: str) -> str:
  text = _URL_USERINFO_PATTERN.sub(r"\1", text)
  for pattern in VALUE_PATTERNS:
    text = pattern.sub(REDACTED, text)
  text = _ASSIGNMENT_PATTERN.sub(_redact_assignment, text)
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
  netloc = parsed.netloc.rsplit("@", 1)[-1]
  if not parsed.scheme or not netloc:
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
  return urlunsplit((parsed.scheme, netloc, path, query, fragment))


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
  segments = [segment.lower() for segment in _KEY_SEGMENT_RE.findall(key)]
  if not segments:
    return False
  if any(segment in _SENSITIVE_KEY_SEGMENTS for segment in segments):
    return True
  if any(segments[i] == "api" and segments[i + 1] == "key" for i in range(len(segments) - 1)):
    return True
  if "token" in segments and not (set(segments) & _TOKEN_METRIC_SEGMENTS):
    return True
  return any(
    segments[i] == "connection" and segments[i + 1] in _CONNECTION_SECRET_SEGMENTS
    for i in range(len(segments) - 1)
  )
