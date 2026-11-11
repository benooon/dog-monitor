# CI status: GREEN

- commit: a572438acc5123b86d35b4a6372a8cb14f33ceed
- message: backend: households.live_encrypted (owner turns it on, never off); live tokens say whether video is end-to-end encrypted
- time (UTC): 2026-11-11T11:55:08Z
- run: https://github.com/benooon/dog-monitor/actions/runs/43015549910

| job | result | log |
|---|---|---|
| core (swift test, Linux) | success | core-test.log |
| ios (xcodebuild test, macOS) | success (carried over, no iOS changes) | ios-build.log |
| backend (lint + test) | success | backend-test.log |
