# Backlog

Agents take the **first** line that is `- [ ]` and not `[blocked]`. Claim it as `- [~] … (in progress YYYY-MM-DD)`, then finish it as `- [x]`.
If a claim is more than 6 hours old and nothing related has been pushed since, treat it as abandoned and take it over.
Add follow-up tasks you discover right below the task that produced them. Keep each task completable in one session (1–3 hours of agent work).

## Phase 0 — Foundations

- [x] core: Create Swift package `ios/Packages/DogMonitorCore` (swift-tools 6.0; platforms iOS 17 / macOS 14; **Linux-compatible, Foundation only**). Add models (`DogState`, `EventType`, `Detection`, `DogEvent`, `CameraHealth`), plus a trivial passing test, so the CI `core` job turns green.
- [x] ios: Create `ios/project.yml` (XcodeGen) with an app target `DogMonitor` (iOS 17, SwiftUI app, bundle id `com.benooon.dogmonitor`, depends on the local DogMonitorCore package), a unit test target `DogMonitorTests`, and Info.plist permission strings (camera, microphone, local network). Add a minimal root view with a "Camera / Viewer" role picker. Add `ios/.gitignore` for `*.xcodeproj` and DerivedData. Goal: the CI `ios` job is green.
- [x] ios: Add a Hebrew + English String Catalog (`Localizable.xcstrings`), and verify the role picker renders in RTL via a SwiftUI preview and a snapshot-free unit test of the localized keys.
- [x] backend: Scaffold `backend/` (Node 22, TypeScript strict, Fastify, ESLint, Vitest, tsx for dev, `npm run build` to `dist/`). Add `GET /health`, `backend/.env.example`, and a `Dockerfile` or Nixpacks config suitable for Railway, plus a test for `/health`. Goal: the CI `backend` job is green.
- [~] backend: Add Drizzle with PostgreSQL. Write the schema from SPEC §9 with migrations and an `npm run migrate` script, and have Vitest run against the CI Postgres service (`DATABASE_URL`). (in progress 2026-11-10)
- [ ] docs: Write `README.md`: what the project is, repo layout, how to run the backend locally, and how CI and the agent loop work.

## Phase 1 — Prototype (one camera, one viewer)

- [ ] backend: Auth. `POST /auth/apple` verifies a Sign in with Apple identity token (JWKS) and returns our JWT. Add JWT middleware. Tests mock the JWKS.
- [ ] backend: Households (create/get), dogs (CRUD), and devices (register device, update APNs token, revoke). Everything is scoped to the caller's household. Add tests.
- [ ] backend: Pairing. `POST /invites` creates a one-time token (10 min) and `POST /invites/:token/accept` consumes it. Camera devices get a device secret, and device auth uses it. Add tests.
- [ ] core: API client (`DogMonitorAPI`) using URLSession async/await with Codable DTOs matching the backend, and a pluggable base URL. Unit test it with a URLProtocol stub. (On Linux, guard with `#if canImport(FoundationNetworking)`.)
- [ ] ios: Sign in with Apple flow, keychain token storage, and household creation screen.
- [ ] ios: Camera capture pipeline. One `AVCaptureSession` (video + audio) with an `AsyncStream` of sample buffers, fanned out to consumers (analysis, recorder, streamer). Add a camera-mode screen: black screen, `isIdleTimerDisabled`, minimum brightness, tap to show preview.
- [ ] ios: Bark detection with SoundAnalysis (`SNClassifySoundRequest` built-in classifier), mapping dog-related classes to `Detection` values in core. Show a debug overlay in camera mode.
- [ ] core: Event engine state machine. Detections in, events out, with duration thresholds, cooldowns, escalation and state transitions per SPEC §5. **Heavy unit tests** with simulated timelines (inject a clock).
- [ ] backend: LiveKit. `POST /cameras/:id/live-token` mints a viewer token; the camera fetches a publisher token. Env: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
- [ ] backend: WebSocket channel. Camera presence and heartbeats; tell the camera "viewer joined / all viewers left"; mark a camera offline after 3 min without a heartbeat.
- [ ] ios: Camera publishes to LiveKit only while viewers are connected (driven by the WebSocket signal), with simulcast 720p/360p.
- [ ] ios: Viewer mode with a camera list and a live view screen (LiveKit subscribe), with reconnect handling.
- [ ] backend: APNs sender (token auth, .p8 from env) and `POST /events` that stores the event and fans out pushes according to `notification_prefs`. Unit test with a mocked APNs client.
- [ ] ios: Push registration, notification categories and actions (Watch live / Mute 1h), and deep link into live view.
- [ ] ios: Notification Service Extension target in project.yml that downloads the snapshot and attaches it to the push.
- [ ] [blocked] ci: TestFlight workflow (`.github/workflows/testflight.yml`). Archive + upload with an App Store Connect API key via `xcodebuild -exportArchive` or fastlane, triggered on every push to main that changes ios/. Needs secrets; see HUMAN_TODO.

## Phase 2 — MVP

- [ ] ios: Pairing UI. The owner shows a QR code + 6-digit code; the new device scans it (AVFoundation metadata output) and joins, then picks a role.
- [ ] ios: Multiple cameras in viewer home (cards with last snapshot, online status, current dog state).
- [ ] ios: Ring-buffer recorder (`AVAssetWriter`, keeping the last ~5 s in memory). On an event, write a 10–20 s clip + snapshot.
- [ ] backend: Storage service interface with an S3/R2 implementation. Presigned upload and download URLs, plus a daily job that deletes clips older than the retention period.
- [ ] ios: Upload clips and snapshots for events through presigned URLs, with an offline queue that retries when the network returns.
- [ ] ios: Event timeline screen (filter by type, play clip, mark detection as right/wrong).
- [ ] backend + ios: Per-user notification settings (types, cameras, quiet hours) with API and screen.
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
