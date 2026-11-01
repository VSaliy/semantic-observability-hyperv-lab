#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import sys
import time

SECRET = b"local-dev-secret-local-dev-secret"
TENANT = sys.argv[1] if len(sys.argv) > 1 else "trading"
header = {"alg": "HS256", "typ": "JWT"}
payload = {
  "sub": "dev-user",
  "tenant": TENANT,
  "iss": "http://localhost:8080/dev-issuer",
  "iat": int(time.time()),
  "exp": int(time.time()) + 3600
}

def b64(data: bytes) -> bytes:
  return base64.urlsafe_b64encode(data).rstrip(b"=")

encoded_header = b64(json.dumps(header, separators=(",", ":")).encode())
encoded_payload = b64(json.dumps(payload, separators=(",", ":")).encode())
signing_input = encoded_header + b"." + encoded_payload
signature = b64(hmac.new(SECRET, signing_input, hashlib.sha256).digest())
print((signing_input + b"." + signature).decode())
