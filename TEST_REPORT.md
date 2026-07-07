# Test Report — v1.4.0

## Completed checks

- Bash syntax validation for all shell scripts.
- Docker Compose YAML parsing and required-service validation.
- GitHub Actions workflow YAML parsing.
- Explicit `--mode online|offline` argument validation.
- Rejection of offline mode without a Bundle.
- Rejection of online mode with an Offline Bundle.
- Generated Offline Bundle wrapper validation for explicit offline mode.
- Mocked online installation and resume flow.
- Mocked Offline Bundle preparation, SHA-256 verification, RPM installation, `docker load`, and `--pull never` flow.
- GitLab Host Header readiness regression test.
- PostgreSQL credential validation flow.
- GitLab root-password extraction regression test.
- Runner registration restart-race regression test.
- Runner TOML duplicate-key normalization and idempotency.
- Release ZIP, tar.gz, and SHA-256 packaging.

## Runtime limitation

The automated test environment does not run a full Rocky Linux systemd host with a real Docker daemon and complete GitLab multi-container startup. A final acceptance test should still be executed on a disposable Rocky Linux 9.x VM before production deployment.
