// The acceptance tests under exercises/ are not a package of their own:
// book/scripts/check_workbook.py overlays each exK directory on the last
// build step (workbook/ch02/step9) before running them. This go.mod only
// keeps them out of every other module's ./... patterns.
module exercises

go 1.27.0
