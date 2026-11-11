# CI status: GREEN

- commit: 8481d2ebb382b4f33512c222143d3cb0d3f3acca
- message: backend: fix audit run 2 findings (ws flood, session leak, membership and limit races, dog cap, limiter eviction)
- time (UTC): 2026-11-11T07:58:55Z
- run: https://github.com/benooon/dog-monitor/actions/runs/42983251106

| job | result | log |
|---|---|---|
| core (swift test, Linux) | success | core-test.log |
| ios (xcodebuild test, macOS) | success (carried over, no iOS changes) | ios-build.log |
| backend (lint + test) | success | backend-test.log |
