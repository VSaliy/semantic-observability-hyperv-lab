"""Print the verified top-five response for the seeded trade incident."""
import json

from evaluate_search import DATASET, TENANT_DOCUMENTS, get_token, search


def main() -> None:
  questions = json.loads(DATASET.read_text(encoding="utf-8"))
  entry = next(q for q in questions if q["id"] == "q-001")
  tenant = entry["tenantId"]
  response = search(entry, get_token(tenant), 5)
  if response["interpretedFilters"] != {
    "tenant": tenant, "environment": entry["environment"], **entry["timeRange"]
  }:
    raise SystemExit("Unexpected tenant, environment or time window for q-001")
  results = response["results"]
  ids = {hit["documentId"] for hit in results}
  allowed = json.loads(TENANT_DOCUMENTS.read_text(encoding="utf-8"))[tenant]
  if len(results) != 5 or len(ids) != 5 or not ids.issubset(allowed):
    raise SystemExit("Expected five distinct seeded trading documents for q-001")
  if not any(hit["type"] == "incident" and hit["documentId"] in entry["expectedDocumentIds"]
             and any(link["url"] for link in hit["evidence"]) for hit in results):
    raise SystemExit("Expected the evidence-linked trade incident in the top five")
  print(json.dumps(response, indent=2))


if __name__ == "__main__":
  main()
