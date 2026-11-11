# CI status: RED

- commit: b4ab27235af33fe27057fc27a7eac0d721cc7385
- message: backend, core, ios: sofa alerts say "on the sofa"
- time (UTC): 2026-11-11T05:08:00Z
- run: https://github.com/benooon/dog-monitor/actions/runs/42963353403

| job | result | log |
|---|---|---|
| core (swift test, Linux) | failure | core-test.log |
| ios (xcodebuild test, macOS) | failure | ios-build.log |
| backend (lint + test) | success | backend-test.log |
