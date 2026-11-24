"""Ephemeral issuer fixture for the disposable CI cluster. Run only inside a temp directory."""
import base64
import json
import subprocess
import time
from pathlib import Path


def encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def encoded_json(value):
    return encode(json.dumps(value, separators=(",", ":")).encode())


issuer = "https://ci-issuer.platform-security.svc.cluster.local"
pub = subprocess.check_output(["openssl", "rsa", "-in", "issuer.key", "-modulus", "-noout"], text=True)
n = bytes.fromhex(pub.strip().split("=")[1])
Path("jwks.json").write_text(json.dumps({"keys": [{"kty": "RSA", "kid": "ci", "alg": "RS256",
                                                   "use": "sig", "n": encode(n), "e": "AQAB"}]}))
Path("openid-configuration").write_text(json.dumps({"issuer": issuer, "jwks_uri": issuer + "/jwks.json",
    "subject_types_supported": ["public"], "response_types_supported": ["id_token"],
    "id_token_signing_alg_values_supported": ["RS256"], "authorization_endpoint": issuer + "/authorize"}))
for tenant in ("trading", "market-data"):
    now = int(time.time())
    message = encoded_json({"alg": "RS256", "kid": "ci"}) + "." + encoded_json({
        "iss": issuer, "sub": tenant, "aud": "trade-search", "tenant": tenant, "iat": now, "exp": now + 3600})
    signature = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", "issuer.key"], input=message.encode())
    Path(tenant + ".jwt").write_text(message + "." + encode(signature))
