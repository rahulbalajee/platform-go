// This module is a fence. It keeps everything under workbook/ out of the root
// module's ./..., because exercise acceptance tests are overlays that only
// compile on top of a step snapshot. Each step snapshot is its own module, and
// book/scripts/check_workbook.py builds and tests them all.
module github.com/rahulbalajee/platform-go/workbook

go 1.27.0
