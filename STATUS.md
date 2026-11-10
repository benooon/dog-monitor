# CI status: RED

- commit: a62451a07fa8e24575acc83b36815cbf6519a712
- message: ci: list failing iOS tests from the result bundle (-quiet hides them)
- time (UTC): 2026-11-10T17:36:04Z
- run: https://github.com/benooon/dog-monitor/actions/runs/42864590963

| job | result | log |
|---|---|---|
| core (swift test, Linux) | success | core-test.log |
| ios (xcodebuild test, macOS) | failure | ios-build.log |
| backend (lint + test) | success | backend-test.log |
