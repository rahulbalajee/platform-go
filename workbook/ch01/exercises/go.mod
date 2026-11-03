// The acceptance tests under exercises/ are not a package of their own:
// book/scripts/check_workbook.py overlays each exK directory on a build
// step (workbook/ch01/stepN) before running them. This go.mod only keeps
// them out of other modules' ./... patterns, where they cannot compile.
module exercises

go 1.27.0
