// The acceptance tests under exercises/ are not a package of their own:
// book/scripts/check_workbook.py overlays each exK directory on a build
// step (workbook/ch04/stepN) before running them. This go.mod only keeps
// them out of the root module's ./... patterns, where they cannot compile.
module exercises

go 1.27.0
