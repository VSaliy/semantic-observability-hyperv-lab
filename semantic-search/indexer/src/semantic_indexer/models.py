from __future__ import annotations

from datetime import UTC, datetime
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator


class Severity(str, Enum):
  INFO = "INFO"
  WARN = "WARN"
  ERROR = "ERROR"
  CRITICAL = "CRITICAL"


class EvidenceReference(BaseModel):
  type: str
  system: str
  url: str


class ServiceRef(BaseModel):
  name: str
  namespace: str
  version: str


class OperationalEvent(BaseModel):
  model_config = ConfigDict(extra="forbid")

  schemaVersion: str
  eventId: str
  eventType: str
  sourceId: str
  timestamp: datetime
  tenantId: str
  environment: str
  service: ServiceRef
  changeId: str | None = None
  severity: Severity
  summary: str
  attributes: dict[str, Any] = Field(default_factory=dict)
  evidence: list[EvidenceReference]

  @field_validator("timestamp")
  @classmethod
  def ensure_utc(cls, value: datetime) -> datetime:
    if value.tzinfo is None:
      raise ValueError("timestamp must include timezone")
    return value.astimezone(UTC)

  @field_validator("tenantId")
  @classmethod
  def tenant_required(cls, value: str) -> str:
    if not value.strip():
      raise ValueError("tenantId is mandatory")
    return value


class Contribution(BaseModel):
  """The projection of one operational event that an aggregate document is rebuilt from."""

  event_id: str
  event_type: str
  timestamp: datetime
  summary: str
  severity: str
  status: str | None = None
  service_name: str
  service_namespace: str
  service_version: str
  change_id: str | None = None
  trace_id: str | None = None
  incident_id: str | None = None
  alert_name: str | None = None
  template: str | None = None
  exception_type: str | None = None
  cause: str | None = None
  resolution: str | None = None
  change_summary: str | None = None
  critical_path: list[str] = Field(default_factory=list)
  symptoms: list[str] = Field(default_factory=list)
  services: list[str] = Field(default_factory=list)
  evidence: list[EvidenceReference]


class SemanticDocument(BaseModel):
  document_id: str
  document_type: str
  tenant_id: str
  environment: str
  timestamp: datetime
  first_seen: datetime
  last_seen: datetime
  service_name: str
  service_namespace: str
  service_version: str
  severity: str
  status: str | None = None
  change_id: str | None = None
  event_id: str
  event_ids: list[str] = Field(default_factory=list)
  occurrences: int = 1
  trace_id: str | None = None
  incident_id: str | None = None
  alert_name: str | None = None
  template: str | None = None
  exception_type: str | None = None
  cause: str | None = None
  resolution: str | None = None
  change_summary: str | None = None
  services: list[str] = Field(default_factory=list)
  symptoms: list[str] = Field(default_factory=list)
  critical_path: list[str] = Field(default_factory=list)
  topology_entities: list[str] = Field(default_factory=list)
  summary: str
  semantic_text: str
  source_references: list[EvidenceReference]
  contributions: list[Contribution] = Field(default_factory=list)
  semantic_vector: list[float] = Field(default_factory=list)
