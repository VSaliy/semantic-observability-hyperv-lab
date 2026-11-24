# Live trade incident

This profile runs a single trading workload and its isolated observability backends. The two HTTP services use a bounded pool of SQLite connections. A trade holds its connection for 800 ms and waits up to 200 ms to acquire one. Four simultaneous requests succeed with the normal pool and compete for one connection during the experiment. No customer traffic or external database is used.

## Prepare the Hyper-V cluster

If the lab already exists, select its dedicated kubeconfig and proceed to acceptance. For a new lab, use elevated PowerShell on the target host. Set `$vhd`, `$iso`, and `$adapter` to the intended VHD directory, Ubuntu Server installer ISO, and physical adapter. Configure the gitignored autoinstall environment and SSH public key as described in [the Hyper-V guide](../../hyperv/README.md).

```powershell
Import-Module ./hyperv/powershell/HyperVLab.psm1 -Force
$check = Test-LabHostReadiness -VhdRootPath $vhd -InstallIsoPath $iso -RequireYaml
if (-not $check.Passed) { throw ($check.Failures -join [Environment]::NewLine) }
./scripts/bootstrap/Start-LabProvisioning.ps1 -VhdRootPath $vhd -InstallIsoPath $iso -ExternalNetAdapterName $adapter -Autoinstall -BuildAutoinstallIso -SkipClusterBootstrap
```

From a Linux/WSL controller with SSH access, Ansible, kubectl, Terraform, and a route to the lab MetalLB network, run the commands below from the repository root. Use the guest SSH account and key from autoinstall. Bootstrap verifies SSH, initializes kubeadm, fetches the control-plane kubeconfig into the dedicated file, and applies the tenant module. Keep that file private.

```bash
export ANSIBLE_REMOTE_USER=labadmin
export KUBECONFIG="$HOME/.kube/hyperv-lab.conf"
ansible-galaxy collection install -r ansible/requirements.yml
bash scripts/deployment/bootstrap-cluster.sh
CTX=$(kubectl config current-context)
bash scripts/validation/check-lab-cluster.sh "$CTX"
```

Repeat provisioning with the same settings and without `-Rebuild`, then repeat bootstrap and acceptance. Check that the same nodes are Ready, both tenants block the test connection, and ingress serves the persisted marker after pod replacement.

## Deploy the profile

Use a lab cluster with NetworkPolicy enforcement, the `local-path` storage class and the four namespaces from bootstrap. Kafka, OpenSearch and Loki are private single-instance backends. Each has a PVC and a NetworkPolicy restricting clients. Only the trading demo pods can submit to the dedicated collector, which sets the tenant at ingestion. The collector sends the structured log to Loki and serializes its body as a normalized Kafka event. Grafana uses the `lab-loki` datasource.

Supply a cluster-accessible registry, a trusted HTTPS OIDC issuer reachable over port 443, and the search API audience. The issuer must issue signed access tokens with `tenant=trading` and `tenant=market-data`. Provide `GRAFANA_PASSWORD` from your lab secret store. For an existing Grafana installation use its current password. Set the following environment variables on the controller before continuing: `REGISTRY`, `ISSUER`, `AUDIENCE`, `GRAFANA_PASSWORD`. Configure pull credentials separately if your registry requires them.

```bash
TAG=$(git rev-parse --short HEAD)
INDEXER_IMAGE="$REGISTRY/live-indexer:$TAG"
QUERY_IMAGE="$REGISTRY/live-query:$TAG"
docker build -t "$INDEXER_IMAGE" semantic-search/indexer
docker build -t "$QUERY_IMAGE" semantic-search/query-api
docker push "$INDEXER_IMAGE"
docker push "$QUERY_IMAGE"
# First installation only. Use the same secret for subsequent deployments.
printf %s "$GRAFANA_PASSWORD" | kubectl --context "$CTX" -n platform-observability create secret generic live-grafana-admin --from-file=password=/dev/stdin
bash scripts/deployment/deploy-live-trade.sh "$CTX" \
  --indexer-image "$INDEXER_IMAGE" --query-image "$QUERY_IMAGE" --issuer "$ISSUER" --audience "$AUDIENCE"
```

## Exercise and inspect the incident

Start these three port-forwards on the controller and keep them running. The default evidence origin is the controller's `http://127.0.0.1:3000`. To use an existing authenticated Grafana route instead, set `--grafana-url` at deployment and pass the same origin to the runner using `--grafana`.

```bash
kubectl --context "$CTX" -n tenant-trading port-forward svc/trade-api 18081:8080 &
kubectl --context "$CTX" -n platform-search port-forward svc/query-api 18080:8080 &
kubectl --context "$CTX" -n platform-observability port-forward svc/grafana 3000:3000 &
```

Export `TRADING_TOKEN` and `MARKET_DATA_TOKEN` from your identity provider and the Grafana password in the controller shell. Run one experiment at a time against this dedicated profile.

```bash
python3 scripts/validation/live_incident.py --context "$CTX" --output target/live-trade.json
```

The report contains the healthy request, rollout change ID, failed and successful requests during contention, recovered request, top five search results, original Loki record, and the market-data control. Open `evidenceLink` while signed into Grafana to see the exact failed event in its absolute time window. The `production` environment label identifies the simulated trading scenario in this lab. If a controller is lost mid-run, inspect the risk-service deployment. For an interrupted demo change restore it with `kubectl --context "$CTX" -n tenant-trading set env deployment/risk-service POOL_SIZE=4 CHANGE_ID=baseline`, wait for rollout, and verify another trade.

The `live-trade` CI job runs the workload in a disposable kind cluster with a temporary signed-token issuer. It archives the report. The separate seeded evaluation continues using its pinned development clock. Hyper-V node provisioning, Cilium policy enforcement, and MetalLB ingress require the target-host acceptance run above.
