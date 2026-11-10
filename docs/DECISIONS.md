# Decisions log

One line per decision: `YYYY-MM-DD — decision — why`.

- 2026-11-10 — Native Swift/SwiftUI rather than Expo — the camera + WebRTC + on-device ML pipeline needs direct AVCaptureSession control; iOS-only for now.
- 2026-11-10 — Build from scratch rather than forking Clearcam — Clearcam is GPL-3 Objective-C and its remote features depend on its closed clearcam.org backend; it may be read as reference only, with no code copied.
- 2026-11-10 — Backend on Railway (Node/TS/Fastify/Postgres) instead of Firebase — the owner already uses Railway.
- 2026-11-10 — LiveKit Cloud as SFU — multiple viewers per camera without overloading the camera phone.
- 2026-11-10 — XcodeGen, no committed .xcodeproj — agents work on Linux and must not hand-edit pbxproj files.
- 2026-11-10 — Agents push directly to main, with no PRs — the owner granted full autonomy; CI results are published to the `ci-results` branch.
- 2026-11-10 — CI decides whether to run the iOS job by diffing against the last commit the iOS job ran on (`ios-sha.txt` in ci-results), not the previous push — with cancel-in-progress, a quick docs push cancelled the iOS run and then reported the old result as carried over.
- 2026-11-10 — Core tests use XCTest (not Swift Testing) — works identically on the Linux container and Xcode; can switch later.
- 2026-11-10 — Backend deploys on Railway via `backend/Dockerfile` + `railway.json` (health check `/health`) rather than Nixpacks — reproducible builds, same image locally.
- 2026-11-10 — Backend dev tooling: ESLint 9 flat config + typescript-eslint, Vitest, tsx; `npm run lint` also runs `tsc --noEmit`.
- 2026-11-10 — DB: `pg` (node-postgres) driver with Drizzle; event types/dog states stored as text (mirroring DogMonitorCore raw values) instead of PG enums so new values need no enum migration; migrations run on Railway via `preDeployCommand` (`npm run migrate:prod`).
- 2026-11-10 — `devices.user_id` (nullable) added beyond SPEC §9 so viewer devices map to users for push fan-out; `notification_prefs.device_id` null means all cameras (unique NULLS NOT DISTINCT, needs PG 15+).
- 2026-11-10 — New backend deps: `jose` (Apple JWKS verification + our HS256 JWTs; zero-dep, standard) and `fastify-plugin` (official, to expose `app.authenticate`). Apple tokens are checked for issuer, audience (`APPLE_AUDIENCES`), RS256 and expiry; nonce checking deferred until the iOS flow sends one.
- 2026-11-10 — MVP: a user belongs to at most one household (`POST /households` returns 409 otherwise) so every route can be scoped without a household id in the path; revisit if multi-household is needed.
- 2026-11-10 — API never returns `device_secret_hash` or raw APNs tokens (only `hasPushToken`); only the owner revokes devices; a device is updated by its own user or the owner.
- 2026-11-10 — Pairing: one invite carries both a long token (QR/link) and a 6-digit code; `POST /invites/:token/accept` takes either, with body `{as: "member"}` (needs user JWT) or `{as: "camera", deviceName}` (no user; returns a one-time `deviceSecret`). Device auth header: `Authorization: Device <deviceId>:<secret>`, secret stored as SHA-256. Failed redemptions are rate-limited per IP in memory (10 per 10 min) against code brute-forcing.
