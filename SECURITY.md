# Security Policy

## Reporting a vulnerability

Please use GitHub Security Advisories for responsible disclosure.

## Secure development rules

- No real credentials or tenant data may be committed.
- Development authentication shortcuts must remain explicitly scoped to local development.
- Tenant identity must be derived from authenticated claims and enforced server-side.
- Evidence URLs are validated and sensitive fields are redacted before indexing or embedding.
