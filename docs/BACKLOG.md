# Backlog

Agents take the **first** line that is `- [ ]` and not `[blocked]`. Claim it as `- [~] … (in progress YYYY-MM-DD)`, then finish it as `- [x]`.
If a claim is more than 6 hours old and nothing related has been pushed since, treat it as abandoned and take it over.
Add follow-up tasks you discover right below the task that produced them. Keep each task completable in one session (1–3 hours of agent work).

## Phase 0 — Foundations

- [x] core: Create Swift package `ios/Packages/DogMonitorCore` (swift-tools 6.0; platforms iOS 17 / macOS 14; **Linux-compatible, Foundation only**). Add models (`DogState`, `EventType`, `Detection`, `DogEvent`, `CameraHealth`), plus a trivial passing test, so the CI `core` job turns green.
- [x] ios: Create `ios/project.yml` (XcodeGen) with an app target `DogMonitor` (iOS 17, SwiftUI app, bundle id `com.benooon.dogmonitor`, depends on the local DogMonitorCore package), a unit test target `DogMonitorTests`, and Info.plist permission strings (camera, microphone, local network). Add a minimal root view with a "Camera / Viewer" role picker. Add `ios/.gitignore` for `*.xcodeproj` and DerivedData. Goal: the CI `ios` job is green.
- [x] ios: Add a Hebrew + English String Catalog (`Localizable.xcstrings`), and verify the role picker renders in RTL via a SwiftUI preview and a snapshot-free unit test of the localized keys.
- [x] backend: Scaffold `backend/` (Node 22, TypeScript strict, Fastify, ESLint, Vitest, tsx for dev, `npm run build` to `dist/`). Add `GET /health`, `backend/.env.example`, and a `Dockerfile` or Nixpacks config suitable for Railway, plus a test for `/health`. Goal: the CI `backend` job is green.
- [x] backend: Add Drizzle with PostgreSQL. Write the schema from SPEC §9 with migrations and an `npm run migrate` script, and have Vitest run against the CI Postgres service (`DATABASE_URL`).
- [x] docs: Write `README.md`: what the project is, repo layout, how to run the backend locally, and how CI and the agent loop work.

## Phase 1 — Prototype (one camera, one viewer)

- [x] backend: Auth. `POST /auth/apple` verifies a Sign in with Apple identity token (JWKS) and returns our JWT. Add JWT middleware. Tests mock the JWKS.
- [x] backend: Households (create/get), dogs (CRUD), and devices (register device, update APNs token, revoke). Everything is scoped to the caller's household. Add tests.
- [x] backend: Pairing. `POST /invites` creates a one-time token (10 min) and `POST /invites/:token/accept` consumes it. Camera devices get a device secret, and device auth uses it. Add tests.
- [x] core: API client (`DogMonitorAPI`) using URLSession async/await with Codable DTOs matching the backend, and a pluggable base URL. Unit test it with a URLProtocol stub. (On Linux, guard with `#if canImport(FoundationNetworking)`.)
- [x] ci: Run the DogMonitorCore package tests on the macOS iOS job too (add `package: DogMonitorCore/DogMonitorCoreTests` to the scheme's test targets in project.yml) so Apple-only compile errors in tests are caught.
- [x] ios: Sign in with Apple flow, keychain token storage, and household creation screen.
- [x] ios: Viewer home placeholder → wire `GET /household` into a real home screen once camera list work starts; also send the Sign in with Apple nonce (SHA-256) and verify it in `POST /auth/apple`.
- [x] ios: Camera capture pipeline. One `AVCaptureSession` (video + audio) with an `AsyncStream` of sample buffers, fanned out to consumers (analysis, recorder, streamer). Add a camera-mode screen: black screen, `isIdleTimerDisabled`, minimum brightness, tap to show preview.
- [x] ios: Bark detection with SoundAnalysis (`SNClassifySoundRequest` built-in classifier), mapping dog-related classes to `Detection` values in core. Show a debug overlay in camera mode.
- [x] core: Event engine state machine. Detections in, events out, with duration thresholds, cooldowns, escalation and state transitions per SPEC §5. **Heavy unit tests** with simulated timelines (inject a clock).
- [x] ios: Run `EventEngine` in camera mode: feed bark/whine `Detection`s from the sound analyzer, call `tick(now:)` every second, show `currentState(at:)` in the camera indicator, and queue `.started`/`.escalated`/`.ended` outputs for `POST /events` (persist the queue for offline retry).
- [x] backend: LiveKit. `POST /cameras/:id/live-token` mints a viewer token; the camera fetches a publisher token. Env: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
- [x] backend: WebSocket channel. Camera presence and heartbeats; tell the camera "viewer joined / all viewers left"; mark a camera offline after 3 min without a heartbeat. Protocol: `backend/src/realtime/protocol.ts`.
- [x] backend: Enforce the 5-viewers-per-camera limit in `POST /cameras/:id/live-token` using WebSocket presence (or LiveKit room participant count), returning 409 `viewer_limit_reached`.
- [x] ios: Camera publishes to LiveKit only while viewers are connected (driven by the WebSocket signal), with simulcast 720p/360p.
- [x] ios: Publish camera audio to LiveKit. AVCaptureSession already owns the mic for bark detection; either feed captured audio into LiveKit's audio pipeline or verify both can share the mic on a device. Viewers currently get video only. (Done via LiveKit manual rendering mode; needs a check on a real device.)
- [~] ios: Viewer audio controls in live view: mute/unmute toggle for the camera's audio track (default unmuted), remembered per viewer; make sure the viewer's audio session plays through the speaker and respects the silent switch choice we document. (in progress 2026-11-10)
- [x] ios: Rotate streamed (and analyzed) video to match the camera phone's orientation (`AVCaptureDevice.RotationCoordinator` → `videoRotationAngle` on the video output connection).
- [x] ios: Pairing UI (moved up: live view needs a paired camera). The owner shows a QR code + 6-digit code; the new device scans it (AVFoundation metadata output) and joins, then picks a role.
- [x] ios: Viewer mode with a camera list and a live view screen (LiveKit subscribe), with reconnect handling.
- [x] backend: APNs sender (token auth, .p8 from env) and `POST /events` that stores the event and fans out pushes according to `notification_prefs`. Unit test with a mocked APNs client. Also `PATCH /events/:id` (end, escalation push) and the camera-offline push.
- [x] backend + ios: Quiet hours. Store each user's time zone (sent by the app) and skip non-time-sensitive pushes inside `quiet_start`–`quiet_end`; the notifier ignores quiet hours today. Done per phone (`devices.time_zone`); time-sensitive alerts still come through. Setting the window from the app is part of the notification settings task.
- [x] ios: Push registration, notification categories and actions (Watch live / Mute 1h), and deep link into live view. Add the push copy keys from `backend/src/notifications/payload.ts` (e.g. "%@ has been barking") to Localizable.xcstrings with Hebrew; category id `DOG_EVENT`.
- [x] backend: Storage service interface with an S3/R2 implementation. Presigned upload and download URLs, plus a daily job that deletes clips older than the retention period. `POST /device/uploads`, `GET /events/:id/media`; pushes carry a 6 h `snapshotUrl`.
- [x] ios: Notification Service Extension target in project.yml that downloads the snapshot and attaches it to the push.
- [ ] [blocked] ci: TestFlight workflow (`.github/workflows/testflight.yml`). Archive + upload with an App Store Connect API key via `xcodebuild -exportArchive` or fastlane, triggered on every push to main that changes ios/. Needs secrets; see HUMAN_TODO.

## Phase 2 — MVP

- [~] ios: Apple-level design pass requested by the owner: design system (`ios/App/Design/`), app icon + accent, Liquid Glass on iOS 26 with fallbacks, and every existing screen redone per `.claude/skills`. CI moves to the newest Xcode on the runner. (in progress 2026-11-10)

- [x] ios: Multiple cameras in viewer home (cards with last snapshot, online status, current dog state).
- [x] ios: Ring-buffer recorder (`AVAssetWriter`, keeping the last ~5 s in memory). On an event, write a 10–20 s clip + snapshot.
- [~] ios: Upload clips and snapshots for events through presigned URLs, with an offline queue that retries when the network returns. (in progress 2026-11-10)
- [x] backend: Viewer timeline API: `GET /events` (household-scoped, newest first, filter by camera and types, cursor pagination) and `PUT /events/:id/feedback` (right/wrong).
- [~] ios: Event timeline screen (filter by type, play clip via `GET /events/:id/media`, mark detection as right/wrong) using `GET /events` and `PUT /events/:id/feedback`. (in progress 2026-11-10)
- [x] backend: Per-user notification settings API (types, cameras, quiet hours). `GET`/`PUT /notification-prefs`.
- [~] ios: Notification settings screen (per event type on/off, per camera overrides, quiet hours) using `GET/PUT /notification-prefs`. (in progress 2026-11-10)
- [ ] ios: Camera health. Heartbeat (battery, charging, thermal, network); show a warning on the camera screen when unplugged or hot, and lower fps on `thermalState` serious.
- [ ] ios: Push-to-talk from viewer to camera (LiveKit audio track published by the viewer, played on the camera).
- [ ] ios: Household members screen with invite link (Universal Link), plus remove member and revoke device.

## Phase 3 — Vision analysis

- [ ] ios: Motion detector (frame differencing at 2–5 fps, per-zone) that gates the heavier analysis.
- [ ] ios: Dog detection (`VNRecognizeAnimalsRequest`) + body pose (`VNDetectAnimalBodyPoseRequest`) → `Detection` values.
- [ ] core: Rule-based state classifier (resting / restless / atDoor / forbiddenZone / notVisible) from detections over time. Unit tests with synthetic sequences.
- [ ] ios: Zone editor in camera setup (draw polygons over the preview, saved as normalized coordinates) and synced to the backend.
- [ ] core + backend: Daily summary computation (rest minutes, bark count, activity by hour), plus a daily summary push.
- [ ] ios: Daily summary screen with Swift Charts.
- [ ] ios: "Calmed down" event and push after barking stops and the dog rests.

## Phase 4 — Custom model

- [ ] ios: Opt-in labeled data capture (save short clips with the user's right/wrong feedback for training).
- [ ] docs: Create ML training guide plus scripts to export labeled data, and a slot in the app to load an updated `.mlmodel`.

## Phase 5 — Product

- [ ] ios: StoreKit 2 subscription (free tier limits vs premium).
- [ ] ios: Live Activity while a camera is active, and a home screen widget with the dog's current state.
- [ ] ios: iPad layout for viewer mode.
