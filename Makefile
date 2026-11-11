.PHONY: check lint test

check: lint test

lint:
	shellcheck -x scripts/*.sh scripts/lib/*.sh agent/*.sh agent/lib/*.sh test/*.sh
	shellcheck tests/*.bats
	python3 -I -c "import ast, sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]" scripts/lib/cidr.py agent/lib/hcloud.py tests/fixtures/fake-curl tests/fixtures/fake-docker

test:
	bats tests/
