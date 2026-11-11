.PHONY: check lint test

check: lint test

lint:
	shellcheck scripts/*.sh

test:
	bats tests/
