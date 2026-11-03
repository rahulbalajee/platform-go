#!/usr/bin/env bash
# Re-run every chapter's capture script. Each one runs from a copy, because
# bash reads scripts incrementally and editing one mid-run corrupts the run.
# Needs Docker, the kind cluster "watchtower" (Chapter 20) and network access.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/capture.XXXXXX")
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
for s in book/scripts/capture-ch*.sh; do
	echo "== $s"
	cp "$s" "$tmp/$(basename "$s")"
	bash "$tmp/$(basename "$s")"
done
