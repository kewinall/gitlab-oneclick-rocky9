# Changelog

## 1.4.0

- Added explicit `install.sh --mode online|offline` selection.
- Added `--online` and `--offline` aliases.
- Added validation that offline mode requires `--offline-bundle`, while online mode rejects it.
- Kept backward compatibility for v1.3-style `--offline-bundle` usage with a deprecation warning.
- Updated generated Offline Bundle wrapper to invoke `--mode offline` explicitly.
- Added unified installation, Runner, troubleshooting, and GitHub publishing documentation.
- Added MIT License, contribution and security policies, issue/PR templates, GitHub Actions CI, Makefile, and release packaging script.
- Added installation-mode regression tests and testable systemd output paths.

## 1.3.0

- Added a two-stage air-gapped installation workflow.
- Added `prepare-offline-bundle.sh` to download Docker/Rocky RPMs with dependencies, Docker signing key, pinned container images, optional CI images, installer files, manifests, and checksums.
- Added `verify-offline-bundle.sh` for SHA-256, format, OS major, and architecture validation.
- Added a self-contained `install-offline.sh` wrapper inside generated bundles.
- Added `install.sh --offline-bundle PATH`.
- Offline installs use `dnf --disablerepo='*'`, `docker load`, and `docker compose up --pull never`.
- Added offline-aware Runner registration, Runner repair, and resume behavior.
- Added offline mocked end-to-end regression tests.

## 1.2.3

- Fixed Runner `config.toml` corruption caused by appending a second `shm_size` key after registration.
- Normalized Docker executor resource keys atomically and retained a timestamped backup.
- Added `scripts/repair-runner.sh` for recovering an already registered Runner without issuing a new token.

## 1.2.2

- Fixed the Runner registration restart race condition.

## 1.2.1

- Fixed initial root-password extraction and `initial_admin.txt` generation.

## 1.2.0

- Fixed false GitLab readiness failure caused by a mismatched HTTP Host header.

## 1.1.1

- Fixed the PostgreSQL credential validation query.

## 1.1.0

- Reworked external PostgreSQL initialization and credential reconciliation.
