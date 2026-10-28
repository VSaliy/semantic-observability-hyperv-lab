from __future__ import annotations

import hashlib
import re
from collections.abc import Iterable
from datetime import UTC
from typing import Any

from semantic_indexer.models import (
  Contribution,
  EvidenceReference,
  OperationalEvent,
  SemanticDocument,
)

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

STATUS_BY_EVENT_TYPE = {
  "deployment.started": "started",
  "deployment.completed": "completed",
  "alert.firing": "firing",
  "alert.resolved": "resolved",
  "incident.created": "open",
  "incident.resolved": "resolved"
}

SEVERITY_RANK = {"INFO": 0, "WARN": 1, "ERROR": 2, "CRITICAL": 3}

# Applied in order: specific shapes first, bare numbers last.
_TEMPLATE_MASKS = (
  (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I), "<id>"),
  (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?\b"), "<ip>"),
  (
    re.compile(
      r"\b\d+(?:\.\d+)?\s*(?:ms|milliseconds?|s|secs?|seconds?|mins?|minutes?|h|hours?)\b",
      re.I
    ),
    "<duration>"
  ),
  (re.compile(r"\b0x[0-9a-f]+\b|\b[0-9a-f]{12,}\b", re.I), "<id>"),
  (re.compile(r"\b\d+(?:\.\d+)?\b"), "<num>")
)


def normalize_template(message: str) -> str:
  template = message
  for pattern, token in _TEMPLATE_MASKS:
    template = pattern.sub(token, template)
  return " ".join(template.split())


def document_type_for(event: OperationalEvent) -> str:
  return DOCUMENT_TYPES[event.eventType]


def document_identity(event: OperationalEvent, document_type: str) -> str:
  """Source identity of the aggregate an event belongs to (see ADR-0004)."""
  if document_type == "log_template":
    exception_type = _attribute(event, "exception.type") or ""
    return "|".join(
      (event.service.name, exception_type, normalize_template(event.summary), _hour(event))
    )
  incident_id = _attribute(event, "incident.id")
  if document_type == "incident" and incident_id:
    return incident_id
  trace_id = _attribute(event, "trace.id")
  if document_type == "trace_summary" and trace_id:
    return trace_id
  if document_type == "change_event" and event.changeId:
    return event.changeId
  alert_name = _attribute(event, "alert.name")
  if document_type == "alert" and alert_name:
    return f"{alert_name}|{_hour(event)}"
  return f"{event.sourceId}|{event.timestamp.astimezone(UTC).strftime('%Y%m%dT%H%M%SZ')}"


def deterministic_document_id(event: OperationalEvent, document_type: str) -> str:
  identity = document_identity(event, document_type)
  raw = f"{event.tenantId}|{event.environment}|{document_type}|{identity}"
  return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def build_contribution(event: OperationalEvent) -> Contribution:
  document_type = document_type_for(event)
  return Contribution(
    event_id=event.eventId,
    event_type=event.eventType,
    timestamp=event.timestamp.astimezone(UTC),
    summary=event.summary,
    severity=event.severity.value,
    status=STATUS_BY_EVENT_TYPE.get(event.eventType),
    service_name=event.service.name,
    service_namespace=event.service.namespace,
    service_version=event.service.version,
    change_id=event.changeId,
    trace_id=_attribute(event, "trace.id"),
    incident_id=_attribute(event, "incident.id"),
    alert_name=_attribute(event, "alert.name"),
    template=normalize_template(event.summary) if document_type == "log_template" else None,
    exception_type=_attribute(event, "exception.type"),
    cause=_attribute(event, "cause"),
    resolution=_attribute(event, "resolution"),
    change_summary=_attribute(event, "change.summary"),
    critical_path=_values(event, "critical.path", ">"),
    symptoms=_values(event, "incident.symptoms", ","),
    services=sorted({event.service.name, *_values(event, "incident.services", ",")}),
    evidence=list(event.evidence)
  )


def aggregate_document(
  document_id: str,
  document_type: str,
  tenant_id: str,
  environment: str,
  contributions: Iterable[Contribution]
) -> SemanticDocument:
  """Rebuild an aggregate from its contributions.

  The result depends only on the set of contributions, never on delivery order, so Kafka
  redelivery and replay converge on the same document.
  """
  by_event = {contribution.event_id: contribution for contribution in contributions}
  ordered = sorted(by_event.values(), key=lambda item: (item.timestamp, item.event_id))
  if not ordered:
    raise ValueError("an aggregate needs at least one contribution")
  first, last = ordered[0], ordered[-1]
  services = sorted({service for item in ordered for service in item.services})
  namespaces = {item.service_namespace for item in ordered}
  document = SemanticDocument(
    document_id=document_id,
    document_type=document_type,
    tenant_id=tenant_id,
    environment=environment,
    timestamp=last.timestamp,
    first_seen=first.timestamp,
    last_seen=last.timestamp,
    service_name=last.service_name,
    service_namespace=last.service_namespace,
    service_version=last.service_version,
    severity=max((item.severity for item in ordered), key=lambda value: SEVERITY_RANK[value]),
    status=_newest(ordered, "status"),
    change_id=_newest(ordered, "change_id"),
    event_id=last.event_id,
    event_ids=[item.event_id for item in sorted(ordered, key=lambda item: item.event_id)],
    occurrences=len(ordered),
    trace_id=_newest(ordered, "trace_id"),
    incident_id=_newest(ordered, "incident_id"),
    alert_name=_newest(ordered, "alert_name"),
    template=_newest(ordered, "template"),
    exception_type=_newest(ordered, "exception_type"),
    cause=_newest(ordered, "cause"),
    resolution=_newest(ordered, "resolution"),
    change_summary=_newest(ordered, "change_summary"),
    services=services,
    symptoms=sorted({symptom for item in ordered for symptom in item.symptoms}),
    critical_path=_newest(ordered, "critical_path") or [],
    topology_entities=sorted({*services, *namespaces}),
    summary="",
    semantic_text="",
    source_references=_merge_evidence(ordered),
    contributions=ordered
  )
  document.summary = _render_summary(document, first, last)
  document.semantic_text = _render_semantic_text(document, ordered)
  return document


def _render_summary(document: SemanticDocument, first: Contribution, last: Contribution) -> str:
  count = document.occurrences
  if document.document_type == "log_template":
    noun = "occurrence" if count == 1 else "occurrences"
    return f"{document.template} ({count} {noun} in {document.service_name})"
  if document.document_type == "incident":
    if document.status == "resolved" and document.resolution:
      return f"{first.summary} Resolved: {document.resolution}."
    return first.summary
  if document.document_type == "alert" and count > 1:
    return f"{last.summary} ({count} notifications)"
  return last.summary


def _render_semantic_text(document: SemanticDocument, ordered: list[Contribution]) -> str:
  change = document.change_id or "none"
  service = document.service_name
  environment = document.environment
  if document.document_type == "log_template":
    return (
      f"{service} in {environment} repeatedly reported: {document.template} "
      f"Exception {document.exception_type or 'unspecified'}. Related change: {change}."
    )
  if document.document_type == "trace_summary":
    path = " > ".join(document.critical_path) or "unknown"
    return (
      f"Trace or latency symptom for {service} in {environment}. "
      f"Summary: {ordered[-1].summary} Critical path: {path}. Related change: {change}."
    )
  if document.document_type == "incident":
    return (
      f"Incident {document.incident_id} for tenant {document.tenant_id} affecting "
      f"{', '.join(document.services)}. Summary: {ordered[0].summary} "
      f"Symptoms: {', '.join(document.symptoms) or 'not specified'}. "
      f"Suspected cause: {document.cause or 'not specified'}. "
      f"Resolution: {document.resolution or 'not yet resolved'}."
    )
  if document.document_type == "change_event":
    return (
      f"Change {change} for {service} version {document.service_version}: "
      f"{ordered[-1].summary} Details: {document.change_summary or 'none'}. "
      f"Status: {document.status or 'unknown'}."
    )
  if document.document_type == "alert":
    wordings = " ".join(dict.fromkeys(item.summary for item in ordered))
    return f"Alert {document.alert_name or 'unnamed'} for {service} in {environment}: {wordings}"
  if document.document_type == "runbook":
    return f"Runbook guidance for {service}: {ordered[-1].summary}"
  return f"{document.document_type} for {service}: {ordered[-1].summary}"


def _newest(ordered: list[Contribution], field: str) -> Any:
  value: Any = None
  for item in ordered:
    candidate = getattr(item, field)
    if candidate:
      value = candidate
  return value


def _merge_evidence(ordered: list[Contribution]) -> list[EvidenceReference]:
  by_url: dict[str, EvidenceReference] = {}
  for item in ordered:
    for reference in item.evidence:
      by_url.setdefault(reference.url, reference)
  return [by_url[url] for url in sorted(by_url)]


def _hour(event: OperationalEvent) -> str:
  return event.timestamp.astimezone(UTC).strftime("%Y%m%dT%H")


def _attribute(event: OperationalEvent, key: str) -> str | None:
  value = event.attributes.get(key)
  return str(value) if value is not None else None


def _values(event: OperationalEvent, key: str, separator: str) -> list[str]:
  value = event.attributes.get(key)
  if value is None:
    return []
  items = value if isinstance(value, list) else str(value).split(separator)
  return [text for text in (str(item).strip() for item in items) if text]
