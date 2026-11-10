# Decisions log

One line per decision: `YYYY-MM-DD — decision — why`.

- 2026-11-10 — Native Swift/SwiftUI rather than Expo — the camera + WebRTC + on-device ML pipeline needs direct AVCaptureSession control; iOS-only for now.
- 2026-11-10 — Build from scratch rather than forking Clearcam — Clearcam is GPL-3 Objective-C and its remote features depend on its closed clearcam.org backend; it may be read as reference only, with no code copied.
- 2026-11-10 — Backend on Railway (Node/TS/Fastify/Postgres) instead of Firebase — the owner already uses Railway.
- 2026-11-10 — LiveKit Cloud as SFU — multiple viewers per camera without overloading the camera phone.
- 2026-11-10 — XcodeGen, no committed .xcodeproj — agents work on Linux and must not hand-edit pbxproj files.
- 2026-11-10 — Agents push directly to main, with no PRs — the owner granted full autonomy; CI results are published to the `ci-results` branch.
