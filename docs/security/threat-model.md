# Threat model: semantic search vertical slice

Scope: the local slice (`docker-compose.dev.yml`) and the code that will be reused in the target
deployment: seed/producer → Kafka `platform.telemetry-events` → Python indexer → OpenSearch alias
`observability-documents` → Spring Boot query API (`POST /api/v1/search`).

**No LLM generates answers.** The query API returns stored, ranked documents verbatim. Stored text is
never executed, templated into a prompt or interpreted as instructions by any component. This
removes the main prompt-injection impact today; it must be revisited before any LLM or agent consumes
search results (see threat 4).

Assets: tenant data in the index, the integrity of search results, evidence links shown to operators,
and the credentials and tokens that gate access. Anything marked *future work* is not implemented.

## Trust boundaries

1. Producers → Kafka: events are untrusted input until validated by the indexer.
2. Indexer → OpenSearch: the indexer is the only writer. OpenSearch security is disabled in dev
   (`DISABLE_SECURITY_PLUGIN=true`), so the network boundary is the only control there.
3. Client → query API: the JWT is the only source of tenant identity.

## Threats

### 1. Search poisoning

- **Asset / attacker:** ranking and content of results. A tenant user or compromised producer emits
  crafted events (keyword stuffing, fake incidents, flooding a template) to push content up or bury
  real evidence.
- **Mitigations:** JSON-Schema validation and dead-lettering of invalid events
  (`semantic-search/indexer/src/semantic_indexer/validation.py`). Documents are aggregates with
  deterministic IDs, so repeating an event cannot multiply documents
  (`semantic_indexer/documents.py`, `semantic_indexer/service.py`). The cosine floor
  `query.min-semantic-similarity` (`application.yaml`, applied in
  `infrastructure/OpenSearchGateway.java`) stops unrelated vectors from padding results. Poison stays
  inside the producing tenant because of the tenant filter.
- **Tests:** `test_invalid_event_reaches_dead_letter_topic`,
  `test_poison_messages_do_not_block_following_payloads`, `test_duplicate_delivery_creates_no_duplicate`,
  `test_log_events_with_same_template_aggregate` (`semantic-search/indexer/tests/test_event_processor.py`).
- **Gaps (future work):** producer authentication and authorisation on Kafka (any client that can
  reach the broker can publish for any `tenantId`); per-tenant rate limits; caps on aggregate size;
  ranking signals that discount unverified sources.

### 2. Cross-tenant leakage

- **Asset / attacker:** other tenants' operational data. An authenticated user of tenant A, or a
  forged request, tries to read tenant B.
- **Mitigations:** the tenant comes only from the JWT claim named by `query.required-tenant-claim`
  (`application/TenantSearchService.java`). The request body rejects unknown fields such as
  `tenantId` (`spring.jackson.deserialization.fail-on-unknown-properties`). Every lexical, vector and
  hybrid query carries server-side `tenant_id` and `timestamp` filters
  (`infrastructure/OpenSearchGateway.java`). Aggregates are never merged across tenants
  (`semantic_indexer/documents.py`). See ADR-0005.
- **Tests:** `TenantIsolationIntegrationTest` (real OpenSearch via Testcontainers, all three search
  modes; CI fails if it is skipped); `SearchControllerTest.derivesTenantFromAuthentication` and
  `rejectsUnknownTenantFieldInRequest`; `test_same_alert_name_in_another_tenant_stays_separate`;
  `make evaluate-search` reports `crossTenantLeakageCount`.
- **Gaps (future work):** OpenSearch has no authentication in dev, so anything that can reach port
  9200 bypasses tenant filtering. The target deployment needs OpenSearch security, network policy
  and per-tenant roles or filtered aliases as defence in depth.

### 3. Manipulated evidence links

- **Asset / attacker:** operators who click evidence links. An event producer smuggles phishing,
  `javascript:` or internal-metadata URLs into `evidence[].url`.
- **Mitigations:** evidence URLs must use `http` or `https` and have a host in the allowlist,
  otherwise the event is dead-lettered (`semantic_indexer/validation.py`). The comparison is on the
  exact authority, so userinfo, ports, case variants and look-alike hosts are rejected. The query API
  re-applies the same allowlist (`query.valid-evidence-hosts`) to every result and drops links that
  fail it (`application/EvidencePolicy.java`, called from `application/TenantSearchService.java`), so
  documents written before an allowlist change, or by anything other than the indexer, cannot hand
  out foreign links.
- **Tests:** `test_evidence_urls_outside_the_allowlist_are_rejected` (schemes, userinfo, ports,
  look-alike hosts), `EvidencePolicyTest`, and
  `TenantIsolationIntegrationTest.evidenceLinksOutsideTheAllowlistAreNotReturned` against real
  OpenSearch.
- **Gaps (future work):** the allowlist is a static host list per deployment, not per tenant, and the
  link target's content is not checked. Dropping a link is silent; add a metric for dropped links.

### 4. Prompt injection stored in indexed documents

- **Asset / attacker:** any future LLM or agent that reads search results. An attacker puts
  instructions in log messages, incident summaries or change descriptions.
- **Mitigations:** none are needed today because no LLM generates answers or consumes results; the
  API returns text as data. Results are scoped to the caller's tenant, which limits whose context an
  attacker can reach.
- **Tests:** none (nothing executes the text).
- **Gaps (future work):** before adding answer generation or agents, treat retrieved text as
  untrusted: delimit it, flag instruction-like content, give the model no tools that act on results
  without confirmation, and add an adversarial evaluation set.

### 5. Sensitive-data leakage into the index or embeddings

- **Asset / attacker:** secrets and personal data in telemetry. Anyone with read access to the
  index, the dead-letter topic, logs or a third-party embedding provider is the attacker.
- **Mitigations:** attribute values whose key contains `password`, `secret`, `token`,
  `authorization`, `connection` or `cookie` are replaced before indexing, embedding and
  every dead letter, including events that fail validation (`semantic_indexer/redaction.py`,
  `semantic_indexer/service.py`). The embedding input is the redacted aggregate text. Messages that
  are not JSON objects are dead-lettered as a size, SHA-256 and origin only, never their bytes.
- **Tests:** `test_redacted_values_never_reach_opensearch`,
  `test_embedding_failure_dead_letter_payload_is_redacted`,
  `test_validation_failure_dead_letter_is_redacted`,
  `test_undecodable_message_is_dead_lettered_without_content_and_committed`.
- **Gaps (future work):** redaction is key-name based. Secrets or personal data inside free-text
  fields or under innocuous keys are not detected; add value-pattern scanners, schema-level
  classification and a retention policy.

### 6. Forged or replayed JWTs

- **Asset / attacker:** identity and tenant claim. An attacker forges a token, replays a stolen one,
  or attempts algorithm confusion.
- **Mitigations:** outside the `dev` profile the API validates tokens only through standard Spring
  resource-server configuration (`spring.security.oauth2.resourceserver.jwt.issuer-uri` or
  `jwk-set-uri`) with the default signature, expiry and not-before checks. An HS256 token is not
  accepted by a JWKS decoder. Without any decoder the application refuses to start
  (`security/SecurityConfiguration.java`). The tenant claim is mandatory
  (`application/TenantSearchService.java`).
- **Tests:** `ResourceServerAuthenticationTest` (an HS256 token signed with the dev secret gets 401, a
  token from the configured JWKS gets 200), `StartupWithoutJwtConfigurationTest`,
  `DevProfileAuthenticationTest` (wrong secret, wrong issuer, no token all give 401).
- **Gaps (future work):** audience validation, a short-lifetime and revocation policy, and
  `jti`-based replay detection. A stolen bearer token is valid until `exp`. Keycloak and TLS
  termination arrive in a later milestone.

### 7. Abuse of the dev authentication shortcut

- **Asset / attacker:** the whole API. Anyone who learns the public dev secret
  (`local-dev-secret-local-dev-secret`, which is in this repository) and reaches a deployment that
  enables the shortcut.
- **Mitigations:** the shared-secret HS256 decoder, the dev issuer and the pinned reference clock
  exist only under the `dev` Spring profile (`security/DevJwtConfiguration.java`,
  `application-dev.yaml`). There is no default secret anywhere else, the profile logs a warning at
  startup, and the secret must be at least 32 bytes. Only `docker-compose.dev.yml` activates the
  profile.
- **Tests:** `DevProfileAuthenticationTest`, `ResourceServerAuthenticationTest`,
  `StartupWithoutJwtConfigurationTest`.
- **Gaps (future work):** nothing technically stops an operator from setting
  `SPRING_PROFILES_ACTIVE=dev` in a shared environment. Add a deployment-policy check (an admission
  rule or a CI check on manifests) that rejects the `dev` profile outside local compose.

### 8. Kafka redelivery and replay

- **Asset / attacker:** index integrity. A crash, a rebalance, an operator replaying a topic, or a
  malicious producer re-sending events causes duplicates or lost events.
- **Mitigations:** the indexer commits `offset + 1` per partition only after
  `EventProcessor.process_payload` returns, so delivery is at-least-once
  (`semantic_indexer/runtime.py`). If processing raises, nothing is committed and the message is
  redelivered after restart. Aggregates are rebuilt from per-event contributions, skip known event IDs
  and use optimistic-concurrency writes, so redelivery and full replays converge on the same
  documents (`semantic_indexer/service.py`, `semantic_indexer/opensearch_io.py`, ADR-0004).
- **Tests:** `test_runtime_commits.py` (commit after success, none on failure, dead letters
  committed); `test_duplicate_delivery_creates_no_duplicate`,
  `test_aggregates_do_not_depend_on_delivery_order`, `test_write_conflict_is_retried`,
  `test_replayed_events_converge_on_aggregates`, `test_stale_write_is_rejected`.
  A message that is not a JSON object is dead-lettered and committed, so one poison message cannot
  block its partition.
- **Gaps (future work):** a replay with a *new* `eventId` is
  indistinguishable from a new event. Commits are per message and synchronous, trading throughput for
  simplicity.
