# Contributing

## Development workflow

1. Review the current milestone status in the root README.
2. Prefer small, reviewable changes that keep Milestone 1 runnable through Docker Compose.
3. Run `make format`, `make test`, and `make validate` before opening a pull request.
4. Keep evidence links deterministic and non-sensitive.
5. Update ADRs or standards when a design decision changes.

## Branch and PR expectations

- Keep tenant isolation and evidence preservation covered by tests.
- Do not commit `.env` files, credentials, or floating image tags.
- Document environment-dependent steps explicitly.
