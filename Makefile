.PHONY: check lint test

check: lint test

lint:
	shellcheck -x scripts/*.sh scripts/lib/*.sh agent/*.sh
	shellcheck tests/*.bats
	python3 -I -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" scripts/lib/cidr.py

test:
	bats tests/
