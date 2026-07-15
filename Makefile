.PHONY: install lint test demo clean

PYTHON ?= python3

install:
	$(PYTHON) -m pip install -r requirements/dev.txt

lint:
	$(PYTHON) -m ruff check src tests dags

test:
	$(PYTHON) -m pytest tests -v

demo:
	$(PYTHON) -m yoda.pipeline --env dev --business-date 2026-07-13 \
		--source-file data/samples/impulse_contracts_20260713.csv

clean:
	rm -rf data/output .pytest_cache .ruff_cache
	find . -type d -name __pycache__ -exec rm -rf {} +
