.PHONY: check lint test

check: lint test

lint:
	shellcheck -x scripts/*.sh scripts/lib/*.sh
	shellcheck tests/*.bats

test:
	bats tests/
