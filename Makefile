SHELL := /usr/bin/env bash

.PHONY: test release clean help

help:
	@printf '%s\n' \
	  'make test     Run static and behavioral tests' \
	  'make release  Build ZIP, tar.gz, and SHA-256 files under dist/' \
	  'make clean    Remove dist/'

test:
	bash tests/run-tests.sh

release: test
	bash scripts/package-release.sh

clean:
	rm -rf dist
