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


class SemanticDocument(BaseModel):
  document_id: str
  document_type: str
  tenant_id: str
  environment: str
  timestamp: datetime
  service_name: str
  service_namespace: str
  service_version: str
  severity: str
  change_id: str | None = None
  event_id: str
  trace_id: str | None = None
  incident_id: str | None = None
  topology_entities: list[str] = Field(default_factory=list)
  summary: str
  semantic_text: str
  source_references: list[EvidenceReference]
  semantic_vector: list[float]
