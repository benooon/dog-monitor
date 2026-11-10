# Progress log

- 2026-11-10 — Repo bootstrapped: CLAUDE.md, SPEC, BACKLOG, CI. Next: Phase 0 tasks.
- 2026-11-10 — Finished all of Phase 0 (core package, XcodeGen app + role picker, he/en String Catalogs, backend scaffold, Drizzle schema, README) and Phase 1 backend auth/households/devices/pairing, core API client, and iOS Sign in with Apple + household creation; fixed CI masking cancelled iOS runs. CI green. Next: ios camera capture pipeline, then bark detection and the core event engine. Note: xcodebuild runs with `-quiet`, so per-test iOS output is not in ios-build.log.
- 2026-11-10 — Added Apple sign-in nonce (backend + iOS) and a viewer home listing cameras/dogs; built the core EventEngine with timeline tests (another agent fixed two Swift compile issues in it — avoid reading `self` inside closures that mutate `self` and keep big literals simple for the type-checker). Next: wire EventEngine into camera mode.
