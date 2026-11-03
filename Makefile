# Platform Go: companion repository
#   make            lint + test the root module
#   make all-tests  everything, including the operator's envtest suite
#   make book       build the PDF (needs typst)

GOLANGCI ?= golangci-lint

.PHONY: default lint test all-tests watchtower-test e2e book widths capture workbook

default: lint test

lint:
	$(GOLANGCI) run ./...

test:
	go test -race -count=1 ./...

watchtower-test:
	$(MAKE) -C projects/watchtower test

all-tests: test watchtower-test

e2e:
	bash projects/watchtower/hack/e2e-kind.sh

widths:
	python3 book/scripts/check_widths.py --max 86

book: widths
	typst compile --root . --font-path book/fonts book/main.typ platform-go.pdf

capture: ## re-run every chapter's capture script (each runs from a copy; needs Docker, kind, network)
	for s in book/scripts/capture-ch*.sh; do cp "$$s" "$${TMPDIR:-/tmp}/run-$$(basename $$s)" && bash "$${TMPDIR:-/tmp}/run-$$(basename $$s)" || exit 1; done

workbook: ## verify the build track: coverage, step and solution modules, exercises, sync
	python3 book/scripts/check_workbook.py --race
