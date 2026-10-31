# ADR-0009 Pinned embedding model rollout

- Status: Deferred (proposal only; no learned model of any kind is adopted until this is reviewed)
- Date: 2026-10-31

## Context

[ADR-0007](ADR-0007-Embedding-provider-abstraction.md) put embeddings behind a provider interface so a pinned model could replace the deterministic one later. That time has come:

- `DeterministicEmbeddingProvider` produces a 16-dimension SHA-256 hash of the text. It carries no meaning.
- The similarity-floor sweep in `semantic-search/evaluation/README.md` showed that lower floors raise the metrics only by padding results with arbitrary documents. Hybrid-weight tuning would tune noise for the same reason.
- `versions.yaml` already pins `sentence-transformers/all-MiniLM-L6-v2` at revision `c9745ed1d9f207416be6d2e6f8de32d1f16199bf`, but nothing uses it.

Current wiring: the indexer calls the embedding service over HTTP (`HttpEmbeddingProvider`) on the aggregate `semantic_text`; the query API calls the same service for the query text. The index mapping `semantic_vector` is `knn_vector`, dimension 16, `cosinesimil`, nmslib (`semantic-search/schemas/opensearch/index-template.json`). The alias `observability-documents` points at `observability-documents-v2`.

## Scope note

The project owner decided to avoid any LLM or learned embedding model for now. This ADR is kept as a proposal for later review. Until then the deterministic provider stays, the similarity floor stays at 0.5, and ranking work is limited to lexical and keyword improvements that need no model.

## Proposal

Serve the pinned model from the existing embedding service, and move the index to a new version behind the alias.

1. **Model.** Use the already-pinned `all-MiniLM-L6-v2` (384 dimensions, Apache-2.0 licence, runs on CPU). It is small and local, so no text leaves the lab. Alternatives to weigh before deciding: a larger local model (better quality, more memory and latency) or a hosted provider (rejected by default, because the threat model treats a third-party embedding provider as an attacker for sensitive data).
2. **Same model on both sides.** The indexer and the query API must embed with the same model and revision, otherwise cosine similarity is meaningless. Both already go through one service, so the revision is pinned in one place. The index document should record `embedding_model` and `embedding_revision`, so a mismatch can be detected and a later model change can be rolled out safely.
3. **Dependencies.** Add the model runtime to `semantic-search/indexer/pyproject.toml`, regenerate `requirements.txt` with `make lock-indexer` on Python 3.12 Linux, and keep `pip check` and `--require-hashes` in the image build. The embedding service shares the indexer image, so the indexer would also carry the model runtime unless the image is split. Splitting into a separate image for the embedding service is the cleaner option and should be decided here.
4. **Model delivery.** Bake the model weights into the image at a pinned revision at build time, and run with the Hugging Face offline flags set. No network fetch at runtime, and CI stays deterministic. The image keeps the non-root user (UID 10001) and needs read access to the weights only.
5. **Index rollout (no downtime).**
   - Create `observability-documents-v3` with `dimension: 384` and the other mapping settings unchanged.
   - Re-embed from the stored `semantic_text` of each v2 document, with a one-off script that reads v2, embeds, and bulk-writes to v3 preserving `_seq_no`-safe writes. Kafka replay is not needed, because aggregates already hold their text.
   - Swap the alias atomically with the `reindex-example.json` pattern, keep v2 until the evaluation gate has passed, and roll back by swapping the alias back.
   - The indexer must write to v3 once the alias moves, so cut the indexer over in the same step to avoid dimension errors.
6. **Floor recalibration.** Repeat the similarity-floor sweep on the new vectors and set `query.min-semantic-similarity` from the result, with the nonsense-query check (no results for gibberish) as a hard requirement.
7. **Version bookkeeping.** Any change updates `versions.yaml` and `docs/standards/version-management.md` together.

## Evaluation gate

The change is acceptable only if all of these hold against `semantic-search/evaluation/baseline.json`:

- cross-tenant leakage is 0;
- no metric falls more than the tolerance below the baseline;
- the paraphrase questions improve (they are the ones a real embedding should help), and the gain is not explained by padding: result counts on the nonsense query stay at 0;
- the evaluation set is grown first. It currently has 34 ranked questions and four paraphrases, which is too few to separate a real gain from noise.

## Risks and open questions

- **Image size and build time.** The CPU model runtime and weights are large compared with the current image. This has not been measured; it needs measuring before the decision, along with Trivy results for the new dependencies (a fixable HIGH or CRITICAL finding fails CI).
- **Latency.** Query-time embedding adds a model inference to every search. Measure it, and keep the existing bounded cache in the indexer.
- **Sensitive data.** Redaction (`semantic_indexer/redaction.py`) covers event attributes by key name, but summaries are free text and are embedded as written. A real model makes leaked text searchable by meaning, so value-pattern redaction of summaries should be done before or together with this change.
- **Prompt-injection text** in documents still has no execution path (no LLM generates answers), but it can now rank by meaning; the evaluation set should include injection-style documents as well as queries.
- **Determinism in tests.** Unit tests and the evaluation gate need stable vectors. Keep the deterministic provider for unit tests, and run the evaluation job with the real model.
- **CI cost.** The evaluation job would need the model in the image; decide whether it is built each run or cached.

## Decision needed

Please decide before implementation:

1. Model: keep `all-MiniLM-L6-v2` (recommended) or choose another.
2. Image layout: one image (simple, heavier indexer) or a separate embedding-service image (recommended).
3. Whether value-pattern redaction of summaries must land first (recommended).
4. Whether to grow the paraphrase part of the evaluation set first (recommended).

## Consequences

- Vector search becomes meaningful, so the similarity floor, hybrid weights and the evaluation metrics can be tuned on real signal.
- A new index version and an alias swap are needed, with a documented rollback.
- The image, lock file and CI evaluation job get heavier.
