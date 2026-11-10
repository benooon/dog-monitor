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
- [x] ios: Viewer audio controls in live view: mute/unmute toggle for the camera's audio track (default unmuted), remembered per viewer; make sure the viewer's audio session plays through the speaker and respects the silent switch choice we document. (998f7a9; plays through the speaker even in silent mode, since opening live view is an explicit request)
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

- ios: Apple-level design pass requested by the owner, split into steps (the original claim from 12:32 had nothing pushed by 16:50, so it was taken over and split):
  - [~] ios: Design system foundation: `ios/App/Design/` tokens (`DS.Spacing`, `DS.Radius`, `DS.Motion`), `GlassCard`, `.glassSurface()`, `PrimaryButton`, `StatusPill` (Liquid Glass on iOS 26, material fallback), app icon (light + dark) and accent color in an asset catalog. (in progress 2026-11-10)
  - [~] ci: Build iOS with the newest stable Xcode on the runner (so `#if compiler(>=6.2)` Liquid Glass code is actually compiled), logging the Xcode version. (in progress 2026-11-10, pushed; waiting for a macOS runner)
  - [~] ios: Redo viewer home and camera cards with the design system (StatusPill on snapshots, ContentUnavailableView for no cameras, symbol effects, numericText). (in progress 2026-11-10)
  - [x] ios: Redo camera mode (floating glass controls over the preview, health warnings as glass cards, Reduce Motion). (327699a, green CI on 682dff2)
  - [~] ios: Redo live view (glass control bar: mute, talk, Lock Screen; connection states as ContentUnavailableView). (in progress 2026-11-10)
  - [~] ios: Redo onboarding: role picker, sign in, create household, pairing (PrimaryButton, copy per the voice in CLAUDE.md). (in progress 2026-11-10)
  - [ ] ios: Redo the sheets: household, notification settings, timeline, daily summary, premium (Form/List conventions, empty/error states, copy pass).

- [x] ios: Multiple cameras in viewer home (cards with last snapshot, online status, current dog state).
- [x] ios: Ring-buffer recorder (`AVAssetWriter`, keeping the last ~5 s in memory). On an event, write a 10–20 s clip + snapshot.
- [x] ios: Upload clips and snapshots for events through presigned URLs, with an offline queue that retries when the network returns. (2d45a0f)
- [x] backend: Viewer timeline API: `GET /events` (household-scoped, newest first, filter by camera and types, cursor pagination) and `PUT /events/:id/feedback` (right/wrong).
- [x] core: Timeline API client: `GET /events` (camera/type filters, cursor pages), `PUT /events/:id/feedback`, `GET /events/:id/media`, and `feedback` on `EventDTO`, with tests. Split out of the timeline screen (whose claim has had nothing pushed since 09:07). (verified by green CI run #138 on 0250ae1)
- [x] ios: Event timeline screen (filter by type, play clip via `GET /events/:id/media`, mark detection as right/wrong) using `GET /events` and `PUT /events/:id/feedback`. (verified by green CI run #143 on fa2f05e)
- [x] backend: Per-user notification settings API (types, cameras, quiet hours). `GET`/`PUT /notification-prefs`.
- [x] ios: Notification settings screen (per event type on/off, per camera overrides, quiet hours) using `GET/PUT /notification-prefs`.
- [x] ios: Camera health. Heartbeat (battery, charging, thermal, network); show a warning on the camera screen when unplugged or hot, and lower fps on `thermalState` serious.
- [x] ios: Push-to-talk from viewer to camera (LiveKit audio track published by the viewer, played on the camera). (Needs a check on real devices: speaker route on the camera while capturing.)
- [x] ios: Household members screen with invite link (Universal Link), plus remove member and revoke device. (Universal Links need the Railway host; see HUMAN_TODO.)

## Phase 3 — Vision analysis

- [x] ios: Motion detector (frame differencing at 2–5 fps, per-zone) that gates the heavier analysis.
- [x] ios: Dog detection (`VNRecognizeAnimalsRequest`) + body pose (`VNDetectAnimalBodyPoseRequest`) → `Detection` values.
- [x] core: Rule-based state classifier (resting / restless / atDoor / forbiddenZone / notVisible) from detections over time. Unit tests with synthetic sequences.
- [x] ios: Zone editor in camera setup (draw polygons over the preview, saved as normalized coordinates) and synced to the backend.
- [x] core + backend: Daily summary computation (rest minutes, bark count, activity by hour), plus a daily summary push.
- [x] ios: Daily summary screen with Swift Charts. (verified by green CI run #132 on 094b952)
- [x] ios: "Calmed down" event and push after barking stops and the dog rests. (verified by green CI run #132 on 094b952)

## Phase 4 — Custom model

- [x] ios: Opt-in labeled data capture (save short clips with the user's right/wrong feedback for training). (verified by green CI run #132 on 094b952)
- [x] docs: Create ML training guide plus scripts to export labeled data, and a slot in the app to load an updated `.mlmodel`. (verified by green CI run #132 on 094b952)

## Phase 5 — Product

- [x] backend: Subscription entitlements for StoreKit 2: verify signed App Store transactions (x5c chain to the Apple root), store the household plan, `GET /subscription`, and enforce the free-tier camera limit.
- [x] backend: App Store Server Notifications V2 endpoint (renewals, expirations, refunds) so premium stays right even when the owner's app is not opened. Uses the same signed-payload verifier.
- [x] ios: StoreKit 2 subscription (free tier limits vs premium). Backend is ready: set `appAccountToken` to the household id, POST each verified `jwsRepresentation` to `/subscription/apple` (after purchase, on `Transaction.updates` and from `currentEntitlements` on launch), read `GET /subscription` for plan/limits, and handle 409 `camera_limit_reached` in pairing with an upgrade prompt. Add a `.storekit` config for local testing. (verified by green CI run #132 on 094b952)
- [x] backend: Live Activity updates. Viewers register an ActivityKit push token per camera (`PUT /live-activities`, `DELETE /live-activities/:id`); dog-state and online changes from the realtime hub are sent as APNs `liveactivity` pushes (throttled, dead tokens dropped).
- [x] core: Live Activity content state (`{state, online}`, matching backend/src/notifications/live-activity.ts) and API calls for `PUT /live-activities` / `DELETE /live-activities/:id`, with tests, so the iOS widget task only adds the extension and UI. (verified by green CI run #138 on 0250ae1)
- [x] ios: Live Activity for a camera on the viewer's phone (dog state + online, Dynamic Island), started from viewer home, registering its push token with `api.registerLiveActivity` / `api.endLiveActivity` and using `CameraLiveActivityContent` as the ContentState (core), (`{cameraId, pushToken}` hex → `{id}`; `DELETE /live-activities/:id` when it ends). ContentState must decode `{"state": DogState?, "online": Bool}` (backend/src/notifications/live-activity.ts); plus a home screen widget with the dog's current state. Needs a widget extension target in project.yml and an app group. (verified by green CI: Live Activity #144 on e6e9a58, widget on dfe60ab; app group needs registering, see HUMAN_TODO)
- [~] ios: Update a showing Live Activity locally from the realtime channel while the app is open (instant, no push round-trip), and end it when the camera is unpaired. (in progress 2026-11-10)
- [~] ios: iPad layout for viewer mode. (in progress 2026-11-10)
