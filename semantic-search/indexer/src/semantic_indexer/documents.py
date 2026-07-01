from __future__ import annotations

import hashlib
from datetime import UTC

from semantic_indexer.models import OperationalEvent, SemanticDocument

DOCUMENT_TYPES = {
  "application.error": "log_template",
  "application.latency": "trace_summary",
  "trace.failure": "trace_summary",
  "deployment.started": "change_event",
  "deployment.completed": "change_event",
  "alert.firing": "alert",
  "alert.resolved": "alert",
  "network.route.changed": "network_event",
  "network.interface.down": "network_event",
  "kafka.consumer.lag": "operational_signal",
  "incident.created": "incident",
  "incident.resolved": "incident",
  "runbook.updated": "runbook"
}


def build_document(event: OperationalEvent, vector: list[float]) -> SemanticDocument:
  document_type = DOCUMENT_TYPES[event.eventType]
  summary = event.summary
  semantic_text = _semantic_text(event, document_type)
  document_id = deterministic_document_id(event, document_type)
  return SemanticDocument(
    document_id=document_id,
    document_type=document_type,
    tenant_id=event.tenantId,
    environment=event.environment,
    timestamp=event.timestamp.astimezone(UTC),
    service_name=event.service.name,
    service_namespace=event.service.namespace,
    service_version=event.service.version,
    severity=event.severity.value,
    change_id=event.changeId,
    event_id=event.eventId,
    trace_id=_attribute(event, "trace.id"),
    incident_id=_attribute(event, "incident.id"),
    topology_entities=[event.service.name, event.service.namespace],
    summary=summary,
    semantic_text=semantic_text,
    source_references=event.evidence,
    semantic_vector=vector
  )


def deterministic_document_id(event: OperationalEvent, document_type: str) -> str:
  identity = _attribute(event, "incident.id") or _attribute(event, "trace.id") or event.sourceId
  timestamp = event.timestamp.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
  raw = f"{event.tenantId}|{document_type}|{identity}|{timestamp}"
  return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def _semantic_text(event: OperationalEvent, document_type: str) -> str:
  if document_type == "log_template":
    return (
      f"{event.service.name} in {event.environment} reported {event.summary}. "
      f"Change {event.changeId or 'none'} and attributes {event.attributes}."
    )
  if document_type == "trace_summary":
    return (
      f"Trace or latency symptom for {event.service.name} in {event.environment}. "
      f"Summary: {event.summary}. Related change: {event.changeId or 'none'}."
    )
  if document_type == "incident":
    return (
      f"Incident for tenant {event.tenantId} affecting {event.service.name}. "
      f"Summary: {event.summary}. Suspected cause: {_attribute(event, 'cause') or 'not specified'}."
    )
  if document_type == "runbook":
    return f"Runbook guidance for {event.service.name}: {event.summary}."
  return f"{document_type} for {event.service.name}: {event.summary}."


def _attribute(event: OperationalEvent, key: str) -> str | None:
  value = event.attributes.get(key)
  return str(value) if value is not None else None
