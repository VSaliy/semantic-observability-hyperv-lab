# ADR-0008 JSON Schema for normalized operational events

- Status: Accepted
- Date: 2026-07-01

## Context

The first vertical slice needs a contract shared by Python, Java, Docker Compose, fixtures, and CI validation without requiring a schema registry or code generation toolchain.

## Decision

Use JSON Schema Draft 2020-12 for Milestone 1 operational events.

## Consequences

- Fixtures and CI can validate the schema with lightweight tooling.
- Python and Java services can evolve independently while sharing the same event contract.
- Later milestones may add Avro or Protobuf around Kafka if registry-backed governance becomes necessary.
