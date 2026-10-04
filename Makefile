.PHONY: check dist
check:
	./scripts/check.sh

dist: check
	python3 scripts/package.py
