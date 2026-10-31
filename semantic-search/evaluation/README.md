# Search evaluation

The evaluation dataset is deterministic and has 17 questions for the `trading` tenant. Metrics include Precision@5, Recall@10, MRR, nDCG@10, query latency, and cross-tenant leakage count.

Leakage counts both a response whose tenant differs from the expected one and any document listed for another tenant in `datasets/tenant-documents.json` appearing in the results. The script exits non-zero when the count is above zero. Document IDs are deterministic hashes, so when the fixtures gain a tenant's events, add that tenant's document IDs to the file.
