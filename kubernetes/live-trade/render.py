"""Render the dedicated lab profile as a Kubernetes List. No cluster access."""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import urlsplit


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TELEMETRY = ROOT / "otel/live-trade"
SEARCH, OBS = "platform-search", "platform-observability"
MSG, TRADING = "platform-messaging", "tenant-trading"
LAYOUT = {
    "kafka": (MSG, 9092), "opensearch": (SEARCH, 9200), "embedding-service": (SEARCH, 8090),
    "semantic-indexer": (SEARCH, None), "query-api": (SEARCH, 8080), "collector": (OBS, 4318),
    "loki": (OBS, 3100), "grafana": (OBS, 3000), "trade-api": (TRADING, 8080),
    "risk-service": (TRADING, 8080),
}
# Explicit allowed connections. All profile pods also need kube-dns.
EDGES = {
    "kafka": ["kafka"], "opensearch": [], "embedding-service": [],
    "semantic-indexer": ["kafka", "opensearch", "embedding-service"],
    "query-api": ["opensearch", "embedding-service"], "collector": ["kafka", "loki"],
    "grafana": ["loki"], "loki": [], "trade-api": ["risk-service", "collector"],
    "risk-service": ["collector"],
}


def resource(kind, name, ns, **fields):
    version = {"Deployment": "apps/v1", "NetworkPolicy": "networking.k8s.io/v1"}.get(kind, "v1")
    return {"apiVersion": version, "kind": kind, "metadata": {"name": name, "namespace": ns}, **fields}


def selector(name):
    return {"matchLabels": {"app.kubernetes.io/name": name}}


def peer(name):
    ns, _ = LAYOUT[name]
    return {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": ns}},
            "podSelector": selector(name)}


def policy(name):
    ns, port = LAYOUT[name]
    dns = {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
           "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}
    egress = [{"to": [dns], "ports": [{"protocol": p, "port": 53} for p in ("UDP", "TCP")]}]
    for target in EDGES[name]:
        ports = [LAYOUT[target][1], 9093] if name == target == "kafka" else [LAYOUT[target][1]]
        egress.append({"to": [peer(target)], "ports": [{"port": p} for p in ports]})
    callers = [peer(source) for source, targets in EDGES.items() if name in targets]
    if name == "query-api":
        callers.append({"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "ingress-nginx"}}})
        egress.append({"ports": [{"port": 443}]})  # External issuer discovery and JWKS.
    ingress = [{"from": callers, "ports": [{"port": port}]}] if callers else []
    if name == "kafka":
        ingress.append({"from": [peer(name)], "ports": [{"port": 9093}]})
    return resource("NetworkPolicy", "live-" + name, ns, spec={
        "podSelector": selector(name), "policyTypes": ["Ingress", "Egress"], "egress": egress, "ingress": ingress})


def workload(name, image, *, env=None, args=None, command=None, files=None, mount=None,
             disk=None, group=None, init=None, health=None):
    ns, port = LAYOUT[name]
    items = [policy(name)]
    container = {"name": name, "image": image}
    pod = {"automountServiceAccountToken": False, "containers": [container], "volumes": []}
    annotations = {}
    if env:
        container["env"] = [{"name": key, **(val if isinstance(val, dict) else {"value": val})}
                            for key, val in env.items()]
    if args:
        container["args"] = args
    if command:
        container["command"] = command
    if group:
        pod["securityContext"] = {"fsGroup": group}
    if files:
        data = {path.name: path.read_text(encoding="utf-8") for path in files}
        items.append(resource("ConfigMap", "live-" + name, ns, data=data))
        annotations["config-sha256"] = hashlib.sha256(json.dumps(data).encode()).hexdigest()
        pod["volumes"].append({"name": "config", "configMap": {"name": "live-" + name}})
        container["volumeMounts"] = [{"name": "config", "mountPath": mount, "readOnly": True}]
    if disk:
        size, directory = disk
        items.append(resource("PersistentVolumeClaim", "live-" + name, ns, spec={
            "accessModes": ["ReadWriteOnce"], "storageClassName": "local-path",
            "resources": {"requests": {"storage": size}}}))
        pod["volumes"].append({"name": "data", "persistentVolumeClaim": {"claimName": "live-" + name}})
        container.setdefault("volumeMounts", []).append({"name": "data", "mountPath": directory})
    if init:
        pod["initContainers"] = init
    if port:
        items.append(resource("Service", name, ns, spec={"selector": selector(name)["matchLabels"],
                              "ports": [{"port": port, "targetPort": port}]}))
        check = {"httpGet": {"path": health, "port": port}} if health else {"tcpSocket": {"port": port}}
        container["readinessProbe"] = {**check, "periodSeconds": 3, "timeoutSeconds": 2}
    items.append(resource("Deployment", name, ns, spec={"replicas": 1, "strategy": {"type": "Recreate"},
                          "selector": selector(name), "template": {"metadata": {
                              "labels": selector(name)["matchLabels"], "annotations": annotations}, "spec": pod}}))
    return items


def render(options):
    schema = ROOT / "semantic-search/schemas"
    broker = "kafka.platform-messaging:9092"
    kafka_image = "confluentinc/cp-kafka:7.7.1"
    items = workload("kafka", kafka_image, group=1000, disk=("4Gi", "/var/lib/kafka/data"), env={
        "KAFKA_NODE_ID": "1", "KAFKA_PROCESS_ROLES": "broker,controller",
        "KAFKA_LISTENERS": "PLAINTEXT://:9092,CONTROLLER://:9093",
        "KAFKA_ADVERTISED_LISTENERS": "PLAINTEXT://" + broker,
        "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP": "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT",
        "KAFKA_CONTROLLER_QUORUM_VOTERS": "1@localhost:9093", "KAFKA_CONTROLLER_LISTENER_NAMES": "CONTROLLER",
        "KAFKA_INTER_BROKER_LISTENER_NAME": "PLAINTEXT", "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR": "1",
        "KAFKA_LOG_DIRS": "/var/lib/kafka/data/logs", "KAFKA_AUTO_CREATE_TOPICS_ENABLE": "false",
        "CLUSTER_ID": "MkU3OEVBNTcwNTJENDM2Qk"})
    items += workload("opensearch", "opensearchproject/opensearch:2.17.0", group=1000,
                      disk=("8Gi", "/usr/share/opensearch/data"), env={
                          "discovery.type": "single-node", "node.store.allow_mmap": "false",
                          "DISABLE_SECURITY_PLUGIN": "true", "DISABLE_INSTALL_DEMO_CONFIG": "true",
                          "OPENSEARCH_JAVA_OPTS": "-Xms512m -Xmx512m"})
    items += workload("embedding-service", options.indexer_image, command=[
        "uvicorn", "semantic_embedding_service.app:app", "--host", "0.0.0.0", "--port", "8090"])
    topics = {"name": "topics", "image": kafka_image, "command": ["bash", "-ec",
              "for topic in platform.telemetry-events semantic.dead-letter; do "
              f"kafka-topics --bootstrap-server {broker} --create --if-not-exists "
              '--topic "$topic" --partitions 3 --replication-factor 1; done']}
    index = {"name": "index", "image": "curlimages/curl:8.8.0",
             "command": ["sh", "/assets/init-opensearch.sh"],
             "volumeMounts": [{"name": "config", "mountPath": "/assets", "readOnly": True}]}
    hosts = [urlsplit(options.grafana_url).netloc]
    items += workload("semantic-indexer", options.indexer_image,
                      files=[schema / "operational-event.schema.json", schema / "opensearch/init-opensearch.sh",
                             schema / "opensearch/index-template.json"], mount="/assets", init=[topics, index], env={
                          "INDEXER_KAFKA_BOOTSTRAP_SERVERS": broker, "INDEXER_OPENSEARCH_URL": "http://opensearch:9200",
                          "INDEXER_SCHEMA_PATH": "/assets/operational-event.schema.json",
                          "INDEXER_EMBEDDING_URL": "http://embedding-service:8090/embed",
                          "INDEXER_TENANT_VALID_EVIDENCE_HOSTS": json.dumps({"trading": hosts})})
    items += workload("query-api", options.query_image, health="/actuator/health", env={
        "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI": options.issuer,
        "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_AUDIENCES": options.audience,
        "SPRING_APPLICATION_JSON": json.dumps({"query": {"tenant-valid-evidence-hosts": {"trading": hosts}}}),
        "OPENSEARCH_URL": "http://opensearch:9200", "EMBEDDING_URL": "http://embedding-service:8090/embed"})
    items += workload("loki", "grafana/loki:3.2.1", files=[TELEMETRY / "loki.yaml"], mount="/etc/live",
                      args=["-config.file=/etc/live/loki.yaml"], disk=("4Gi", "/loki"), group=10001, health="/ready")
    items += workload("grafana", "grafana/grafana:11.2.2", files=[TELEMETRY / "datasources.yaml"],
                      mount="/etc/grafana/provisioning/datasources", disk=("1Gi", "/var/lib/grafana"), group=472,
                      health="/api/health", env={"GF_SECURITY_ADMIN_PASSWORD": {"valueFrom": {
                          "secretKeyRef": {"name": "live-grafana-admin", "key": "password"}}}})
    items += workload("collector", "otel/opentelemetry-collector-contrib:0.108.0",
                      files=[TELEMETRY / "collector.yaml"], mount="/etc/live", args=["--config=/etc/live/collector.yaml"])
    for name in ("risk-service", "trade-api"):
        items += workload(name, "python:3.12.12-slim", files=[ROOT / "applications/live-trade/service.py"],
                          mount="/app", command=["python", "-B", "/app/service.py"], health="/health", env={
                              "ROLE": name, "POOL_SIZE": "4", "CHANGE_ID": "baseline",
                              "GRAFANA_URL": options.grafana_url, "RISK_URL": "http://risk-service:8080/check",
                              "OTLP_LOGS_URL": "http://collector.platform-observability:4318/v1/logs"})
    return {"apiVersion": "v1", "kind": "List", "items": items}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("indexer-image", "query-image", "issuer", "audience"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--grafana-url", default="http://127.0.0.1:3000")
    options = parser.parse_args()
    if urlsplit(options.issuer).scheme != "https":
        parser.error("Supply the HTTPS issuer of the access tokens used for this cluster.")
    print(json.dumps(render(options), indent=2))
