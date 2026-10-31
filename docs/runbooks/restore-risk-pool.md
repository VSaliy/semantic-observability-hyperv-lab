# Runbook: Restore previous risk-service database pool configuration

## Symptoms

- Trade requests intermittently return HTTP 503.
- `risk-service` emits database connection acquisition timeouts.
- Kafka consumer lag rises because retries amplify traffic.

## Investigation

1. Confirm the latest completed deployment references `CHG-0184`.
2. Compare the deployed pool size against the prior known-good value.
3. Validate trace failures and log template matches in the tenant-scoped search API.

## Remediation

1. Roll back `risk-service` pool settings to the prior release profile.
2. Restart affected pods if the configuration source does not hot reload.
3. Confirm error rates and queue lag fall back to baseline.

## Validation

- Search results show the deployment event, incident, trace summary, and log template.
- Evidence links remain reachable and tenant-scoped.
