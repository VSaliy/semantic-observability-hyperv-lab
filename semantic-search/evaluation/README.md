# Search evaluation

The evaluation dataset is deterministic and has 44 questions over three tenants: 24 for `trading`, 9 for `market-data` and 11 for `payments`. Each question runs with a token for its own tenant (`scripts/bootstrap/generate-dev-jwt.py <tenant>`). Ten are negative controls with no expected document, including cross-tenant and injection-style queries; they count towards leakage but not towards the ranking metrics. Metrics include Precision@5, Recall@10, MRR, nDCG@10, query latency, and cross-tenant leakage count.

Baseline on the seeded dev stack (21 documents, 34 ranked questions): P@5 0.224, R@10 0.775, MRR 0.701, nDCG@10 0.646, leakage 0. The values were identical over three runs and after re-seeding. Earlier baselines (21 ranked questions: P@5 0.257, R@10 0.771, MRR 0.734, nDCG@10 0.651; before that a trading-only set) are not comparable.

Four questions are tagged `paraphrase`: they avoid the words used in the target documents. With the hash embedding they only succeed through incidental word overlap (q-037 to q-039 find most of their expected documents through shared words such as "database" and "latency"; q-040 finds none). They are too few to separate a real embedding gain from noise on their own, so grow them when the embedding work starts.

Leakage counts both a response whose tenant differs from the expected one and any document listed for another tenant in `datasets/tenant-documents.json` appearing in the results. The script exits non-zero when the count is above zero. Document IDs are deterministic hashes, so when the fixtures gain a tenant's events, add that tenant's document IDs to the file.

## Baseline gate

- `baseline.json` holds the accepted metrics and a `tolerance` of 0.005.
- `evaluate_search.py --check-baseline semantic-search/evaluation/baseline.json` exits non-zero on any cross-tenant leakage or when a metric falls more than the tolerance below the baseline.
- `scripts/validation/run-evaluation.sh` starts the dev stack, seeds it, waits for the expected document count and runs that gate. CI runs it as the `evaluation` job in `container-and-dependencies.yml`.
- When a change improves ranking, raise the baseline in the same PR. When the fixtures change, update the baseline and `EXPECTED_DOCUMENTS` deliberately.

## Similarity-floor sweep

Measured on the seeded dev stack (16 documents, 21 ranked questions, `mode: HYBRID`; measured before the `payments` tenant was added) by setting `QUERY_API_MIN_SEMANTIC_SIMILARITY` and re-running `evaluate_search.py`. Leakage was 0 in every run.

| Floor | P@5 | R@10 | MRR | nDCG@10 |
| ----- | --- | ---- | --- | ------- |
| 0.5 (default) | 0.257 | 0.771 | 0.734 | 0.652 |
| 0.2 | 0.286 | 0.854 | 0.775 | 0.703 |
| 0.0 | 0.267 | 0.882 | 0.817 | 0.743 |
| -0.2 | 0.276 | 0.981 | 0.821 | 0.778 |
| -1.0 | 0.276 | 0.981 | 0.811 | 0.776 |

Lower floors score higher, but the gain is an artifact and the default stays at 0.5:

- The pinned embedding is a hash of the text and carries no meaning (see the README limitations), so the vector side contributes arbitrary matches, not semantic ones.
- With about 11 documents per tenant, a low floor pads every query to the full 10 results (at -0.2 every `trading` query returned exactly 10, against 6.6 on average at 0.5). Recall and nDCG rise because the correct documents are somewhere in the padding.
- At 0.5 a nonsense query returns no results; the lower floors would return arbitrary documents. That padding is the behaviour the floor exists to prevent (`docs/security/threat-model.md`, search poisoning).

Recalibrate the floor, and repeat this sweep, when a real embedding model replaces the hash embedding. Until then the baseline in `baseline.json` stays as is.
