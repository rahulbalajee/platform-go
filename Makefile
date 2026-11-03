# Platform Go: companion repository
#   make            lint + test the root module
#   make all-tests  everything, including the operator's envtest suite
#   make book       build the PDF (needs typst)

GOLANGCI ?= golangci-lint

.PHONY: default lint test all-tests watchtower-test e2e book widths capture

default: lint test

lint:
	$(GOLANGCI) run ./...

test:
	go test -race -count=1 ./...

watchtower-test:
	$(MAKE) -C projects/watchtower test

all-tests: test watchtower-test

e2e:
	projects/watchtower/hack/e2e-kind.sh

widths:
	python3 book/scripts/check_widths.py --max 86

book: widths
	typst compile --root . --font-path book/fonts book/main.typ platform-go.pdf

capture:
	book/scripts/capture-ch04.sh
	OUT=../../book/output/wt projects/watchtower/hack/e2e-kind.sh
