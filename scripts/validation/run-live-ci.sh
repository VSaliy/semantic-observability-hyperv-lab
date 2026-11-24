#!/usr/bin/env bash
# The caller supplies a newly created, disposable kind cluster and two locally built images.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
context=kind-live-trade-ci
k=(kubectl --context "$context")
work=$(mktemp -d)
cd "$work"
umask 077
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -f issuer.key trading.jwt market-data.jwt grafana-password
}
trap cleanup EXIT
"${k[@]}" apply -f "$root/kubernetes/platform/namespaces.yaml"
for tenant in trading market-data; do "${k[@]}" create namespace "tenant-$tenant"; done
issuer=ci-issuer.platform-security.svc.cluster.local
openssl req -x509 -nodes -newkey rsa:2048 -subj "/CN=$issuer" -days 1 \
  -addext "subjectAltName=DNS:$issuer" -keyout issuer.key -out issuer.crt 2>/dev/null
python3 "$root/scripts/validation/live-ci-identity.py"
cat > default.conf <<'CONF'
server {
  listen 443 ssl;
  ssl_certificate /tls/tls.crt;
  ssl_certificate_key /tls/tls.key;
  location / { root /usr/share/nginx/html; default_type application/json; }
  location = /.well-known/openid-configuration { default_type application/json; alias /usr/share/nginx/html/openid-configuration; }
}
CONF
ks=("${k[@]}" -n platform-security)
"${ks[@]}" create secret tls ci-issuer --cert=issuer.crt --key=issuer.key
"${ks[@]}" create configmap discovery --from-file=jwks.json --from-file=openid-configuration
"${ks[@]}" create configmap ci-nginx --from-file=default.conf
"${ks[@]}" create deployment ci-issuer --image=nginx:1.27.4-alpine
"${ks[@]}" patch deploy ci-issuer --type=strategic -p '{
  "spec":{"template":{"spec":{"volumes":[{"name":"tls","secret":{"secretName":"ci-issuer"}},
    {"name":"data","configMap":{"name":"discovery"}},{"name":"conf","configMap":{"name":"ci-nginx"}}],
    "containers":[{"name":"nginx","volumeMounts":[{"name":"tls","mountPath":"/tls"},
    {"name":"data","mountPath":"/usr/share/nginx/html"},{"name":"conf","mountPath":"/etc/nginx/conf.d"}]}]}}}}'
"${ks[@]}" expose deploy ci-issuer --port=443
keytool -importcert -noprompt -keystore trust.p12 -storepass changeit -file issuer.crt -alias ci >/dev/null
"${k[@]}" -n platform-search create configmap ci-trust --from-file=trust.p12
openssl rand -hex 24 | tr -d '\n' > grafana-password
"${k[@]}" -n platform-observability create secret generic live-grafana-admin --from-file=password=grafana-password
# Inject the CI CA into this release only. The live profile uses normal JVM issuer trust.
python3 "$root/kubernetes/live-trade/render.py" --issuer "https://$issuer" --audience trade-search \
  --query-image live-query:ci --indexer-image live-indexer:ci > profile.json
python3 - <<'PY'
import json
from pathlib import Path
p = Path("profile.json")
profile = json.loads(p.read_text())
api = next(r for r in profile["items"] if r["kind"] == "Deployment" and r["metadata"]["name"] == "query-api")
pod = api["spec"]["template"]["spec"]
pod["volumes"].append({"name":"ca","configMap":{"name":"ci-trust"}})
c = pod["containers"][0]
c["volumeMounts"] = [{"name":"ca","mountPath":"/ca","readOnly":True}]
c["env"].append({"name":"JAVA_TOOL_OPTIONS","value":"-Djavax.net.ssl.trustStore=/ca/trust.p12 -Djavax.net.ssl.trustStorePassword=changeit"})
# kind's dynamic provisioner uses the "standard" StorageClass.
for r in profile["items"]:
    if r["kind"] == "PersistentVolumeClaim":
        r["spec"]["storageClassName"] = "standard"
p.write_text(json.dumps(profile))
PY
"${k[@]}" apply -f profile.json
for ns in platform-security platform-messaging platform-observability platform-search tenant-trading; do
  "${k[@]}" -n "$ns" rollout status deployment --timeout=6m
done
forward() {
  "${k[@]}" -n "$1" port-forward "svc/$2" "$3" > "forward-$2.log" 2>&1 &
  pids+=("$!")
  for _ in {1..40}; do
    if grep -q 'Forwarding from' "forward-$2.log"; then return; fi
    sleep 1
  done
  cat "forward-$2.log" >&2
  return 1
}
forward tenant-trading trade-api 18081:8080
forward platform-search query-api 18080:8080
forward platform-observability grafana 3000:3000
TRADING_TOKEN=$(<trading.jwt)
MARKET_DATA_TOKEN=$(<market-data.jwt)
GRAFANA_PASSWORD=$(<grafana-password)
export TRADING_TOKEN MARKET_DATA_TOKEN GRAFANA_PASSWORD
python3 "$root/scripts/validation/live_incident.py" --context "$context" --output "$root/target/live-trade.json"
