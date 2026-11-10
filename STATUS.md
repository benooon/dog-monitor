# CI status: RED

- commit: c3f6a2c8def33b49572e45b85a0c90d55fc29ee3
- message: ci: build iOS with the newest stable Xcode on the runner and log its version
- time (UTC): 2026-11-10T17:09:53Z
- run: https://github.com/benooon/dog-monitor/actions/runs/42860689562

| job | result | log |
|---|---|---|
| core (swift test, Linux) | success | core-test.log |
| ios (xcodebuild test, macOS) | failure | ios-build.log |
| backend (lint + test) | success | backend-test.log |
