#!/usr/bin/env bash
# Run from a controller with a route to the lab's MetalLB address.
set -euo pipefail
context=${1:?Usage: bash scripts/validation/check-lab-cluster.sh LAB_CONTEXT}
k=(kubectl --context "$context" --request-timeout=150s)
for node in k8s-cp1 k8s-worker1 k8s-worker2; do
  "${k[@]}" wait --for=condition=Ready "node/$node" --timeout=90s
done
tenants=(tenant-trading tenant-market-data)
for tenant in "${tenants[@]}"; do
  "${k[@]}" -n "$tenant" get networkpolicy/default-deny "resourcequota/${tenant#tenant-}-quota"
done

ns=$(printf '%s\n' '{"apiVersion":"v1","kind":"Namespace","metadata":{"generateName":"lab-check-"}}' |
  "${k[@]}" create -f - -o jsonpath='{.metadata.name}')
probes=()
cleanup() {
  for tenant in "${probes[@]}"; do
    "${k[@]}" -n "$tenant" delete pod "$ns" --ignore-not-found --wait=false || true
  done
  "${k[@]}" delete namespace "$ns" --wait=false || true
}
trap cleanup EXIT
kn=("${k[@]}" -n "$ns")
host="$ns.lab.example.com"
lb=$("${k[@]}" -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
: "${lb:?No MetalLB address on ingress-nginx-controller}"
"${kn[@]}" create -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: evidence
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 16Mi
YAML
start_server() {
  "${kn[@]}" create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  containers:
    - name: web
      image: busybox:1.36.1
      command: [httpd, -f, -p, "8080", -h, /data]
      readinessProbe:
        tcpSocket: {port: 8080}
      volumeMounts:
        - {name: data, mountPath: /data}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: evidence}
YAML
  "${kn[@]}" wait --for=condition=Ready pod/web --timeout=120s
}
start_server
"${kn[@]}" exec web -- sh -c 'echo "$1" > /data/marker' sh "$ns"
"${kn[@]}" expose pod web --port=80 --target-port=8080
"${kn[@]}" create ingress web --class=nginx --rule="$host/*=web:80"
read_ingress() {
  local response
  for _ in {1..30}; do
    if response=$(curl --noproxy '*' -fsS --max-time 3 --resolve "$host:80:$lb" "http://$host/marker") && [[ $response == "$ns" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Ingress failed to return the marker for $ns" >&2
  return 1
}
read_ingress
"${kn[@]}" delete pod web --wait=true --timeout=90s
start_server
read_ingress
echo "Ingress served the original PVC marker after pod replacement."

ip=$("${kn[@]}" get pod web -o jsonpath='{.status.podIP}')
url="http://$ip:8080/marker"
# Use the same image, destination and command for the allowed and denied paths.
probe() {
  "${k[@]}" -n "$1" exec "$2" -- sh -c 'wget -q -T 3 -t 1 -O - "$1" || echo blocked' sh "$url"
}
start_probe() {
  "${k[@]}" -n "$1" run "$ns" --image=busybox:1.36.1 --restart=Never --command -- sleep 300
}
start_probe "$ns"
"${kn[@]}" wait --for=condition=Ready "pod/$ns" --timeout=120s
[[ $(probe "$ns" "$ns") == "$ns" ]] || { echo "Control pod could not read the marker" >&2; exit 1; }
for tenant in "${tenants[@]}"; do
  start_probe "$tenant"
  probes+=("$tenant")
  "${k[@]}" -n "$tenant" wait --for=condition=Ready "pod/$ns" --timeout=120s
  [[ $(probe "$tenant" "$ns") == blocked ]] || { echo "Unexpected probe result for $tenant" >&2; exit 1; }
  echo "$tenant blocked egress to the test workload."
done
