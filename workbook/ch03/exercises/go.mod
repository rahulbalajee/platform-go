// The acceptance tests under exercises/ are not a package of their own:
// book/scripts/check_workbook.py overlays each exK directory on a build
// step (workbook/ch03/step8) before running them. This go.mod only keeps
// them out of any ./... pattern run above this directory.
module exercises

go 1.27.0
