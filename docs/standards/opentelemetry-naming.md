# OpenTelemetry naming standard

All telemetry entering the platform must provide or be enriched with:

- `service.name`
- `service.namespace`
- `service.version`
- `deployment.environment.name`
- `team.owner`
- `tenant.id`
- `change.id`

Missing mandatory attributes are quarantined by the gateway collector or downstream validation.
