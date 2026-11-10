# Dog Monitor — Product & Technical Spec

A native iPhone app that turns a spare iPhone into a smart dog camera, similar to Barkio. One or more devices act as **cameras**, and family members' phones act as **viewers**: they watch live, get push notifications, and browse an event timeline. The core differentiator is **on-device analysis of the dog's state** (resting, barking, whining, restless, at the door, in a forbidden zone), so that pushes are sent only for meaningful events.

## 1. Goals

- Low-latency live view (under 1 s) from any camera to any viewer.
- Multiple cameras and multiple viewers in one household.
- Dog-state detection from video and audio, with per-user push preferences.
- An event timeline with short clips and snapshots.
- A daily summary: time resting, bark count, most active hours.

## 2. Roles and scenarios

- **Camera:** a spare iPhone left at home on a charger with the app in camera mode. It captures, analyzes, and streams.
- **Viewer:** each family member's own phone. It watches live, receives pushes, and can talk to the dog (push-to-talk).
- A device can switch roles from inside the app.

Scenarios: leave home → tap "Start camera". At work, get a push like "Rex has been barking for 2 minutes" with a snapshot → open live view → talk to calm him. A partner gets only "prolonged barking" pushes, per their own settings. In the evening, check the daily summary. Two cameras (living room and front door), with switching between them in the viewer.

## 3. Multi-device

- **Household:** all devices and users belong to a household, which has an owner and members.
- **Sign-in:** Sign in with Apple. The backend issues its own JWT.
- **Pairing:** the owner shows a QR code (or a 6-digit code) holding a one-time invite token valid for 10 minutes. The new device scans it and joins. Family members join with an invite link (Universal Link).
- A camera device does not need a signed-in user. It gets its own device token, which the owner can revoke remotely.
- MVP limits: up to 4 cameras per household, up to 5 concurrent viewers per camera, up to 6 users per household.
- **Streaming topology:** an SFU (LiveKit Cloud). The camera publishes one track with simulcast (720p and 360p), and the SFU fans it out. When no viewer is connected, the camera **does not publish video**; it only analyzes locally. Publishing starts when a viewer joins and stops about 30 s after the last viewer leaves.

## 4. On-device analysis (camera device)

All analysis runs on the camera device. Video is never sent to the cloud for analysis.

**Audio:** SoundAnalysis `SNClassifySoundRequest` (built-in classifier) on 1 s overlapping windows. It detects dog bark, howl, whimper/whine and growl, keeping only results with confidence ≥ 0.7 (configurable). An RMS level meter adds generic loud-noise detection.

**Video, in three layers:**
1. Motion: frame differencing at 2–5 fps inside user-defined regions. This is cheap, and the heavier layers are skipped when nothing changes.
2. Dog detection: Vision `VNRecognizeAnimalsRequest` (dog bounding box) plus `VNDetectAnimalBodyPoseRequest` (pose).
3. State classification: rule-based in the MVP (pose, location, motion over time). A Create ML / Core ML classifier comes later.

**States:**

| State | Signal |
|---|---|
| resting | dog in frame, lying pose, very little motion for 2+ min, quiet |
| barking | bark sound class (stronger when combined with head motion) |
| whining | whimper/howl sound class |
| restless | continuous motion, moving between zones, standing or walking |
| atDoor | dog inside the "door" zone for more than X s |
| forbiddenZone | dog inside a zone marked forbidden (sofa, kitchen) |
| notVisible | no dog in frame for more than X min |

**Calibration:** in camera setup, the user draws zones (door, forbidden, bed) over the preview. Each event in the timeline can be marked right or wrong, which tunes per-household thresholds.

**Performance:** run Vision and Core ML on the Neural Engine at 1–3 analyses per second, only when there is motion. Adapt to `ProcessInfo.thermalState` by lowering the analysis rate and stream quality as the device heats up.

## 5. Events and pushes

**Event engine** (pure Swift, in `DogMonitorCore`): a state machine that turns raw detections into events.
- Duration thresholds: barking becomes an event only after X s, or Y barks within a minute.
- Cooldown per event type (default 5 min). An escalation update ("barking for 5 minutes") is still sent.
- Events fire on state transitions (resting → barking), not on every frame.
- Each event saves a 10–20 s clip (including 5 s from before the event, from a ring buffer) and a snapshot.

**Push types:**

| Push | Default | Interruption level |
|---|---|---|
| prolonged barking | on | time-sensitive |
| whining / howling | on | time-sensitive |
| forbidden zone | off | active |
| at door | off | active |
| not visible for long | off | active |
| calmed down / resting after an event | on | passive |
| camera offline / low battery / overheating | on | time-sensitive |
| daily summary | on | passive |

**Per-viewer settings:** which event types, from which cameras, quiet hours, and an optional "I'm home" mute.

**Push format:** a rich notification with the snapshot (Notification Service Extension), actions "Watch live", "Talk", "Mute 1h", and `threadIdentifier` set per camera. Sent from the backend via APNs only.

## 6. Architecture

**iOS app** (one app, two modes): Swift 6, SwiftUI, AVFoundation (`AVCaptureSession` feeding the LiveKit publisher, the analysis pipeline, and an `AVAssetWriter` ring-buffer recorder from one capture session), Vision, Core ML, SoundAnalysis, LiveKit Swift SDK, UserNotifications with a Notification Service Extension. The project is generated with XcodeGen.

**Backend** (Railway):

| Component | Choice | Role |
|---|---|---|
| API | Node 22 + TypeScript + Fastify | auth, households, pairing, devices, events, settings |
| DB | PostgreSQL (Railway) + Drizzle | all relational data |
| Realtime | WebSocket channel on the API | presence, viewer-joined signals, camera heartbeats |
| Media | LiveKit Cloud | SFU + TURN; the API mints room tokens |
| Storage | S3-compatible (R2) | clips and snapshots, presigned upload and download, auto-delete after 7 days |
| Push | APNs (HTTP/2, .p8 token auth) | notifications |

**Live view flow:** the viewer requests a LiveKit token for camera X → the API notifies the camera over WebSocket → the camera joins the room and publishes → the viewer subscribes. Additional viewers join the same room.

**Event flow:** the camera detects an event → uploads the clip and snapshot via presigned URLs → POSTs `/events` → the API fans out APNs to viewers according to their preferences.

**Health:** the camera sends a heartbeat every 30–60 s (battery, charging, thermal state, network). With no heartbeat for 3 min, the API pushes "camera offline".

## 7. iOS limitations and mitigations

- The camera cannot run in the background or while locked, so camera mode stays in the foreground. Set `isIdleTimerDisabled`, show a black screen at minimum brightness, and wake on tap.
- To prevent the user leaving the app by accident, the setup guide recommends Guided Access.
- Heat: monitor thermal state, lower fps and resolution, analyze only on motion, and stream only while someone is watching.
- Battery: the device must stay on the charger. Alert on unplug, or when the battery drops below 20%.
- Network drops: reconnect automatically, queue events locally, and upload when the network returns.
- Permissions: camera, microphone, notifications and local network, with clear Info.plist strings.

## 8. Screens

- **Common:** onboarding (sign in, create household, dog profile with name and photo), role selection, and settings (household, members, devices).
- **Camera mode:** setup (placement, zone drawing, audio test). The active screen is black with a small indicator (recording, connected viewers, current dog state); a tap shows the preview and a stop button. On-screen warnings cover heat and unplugged power.
- **Viewer mode:**
  - Home: a card per camera with last snapshot, online status, and current dog state (e.g. "resting for 40 min").
  - Live view: push-to-talk, snapshot, manual record, camera switcher.
  - Timeline: filter by type, clip playback, "wrong detection" feedback.
  - Daily summary chart.
  - Notification settings.

## 9. Data model (Postgres)

- `users` (id, apple_sub, name)
- `households` (id, name, owner_id, plan)
- `household_members` (household_id, user_id, role)
- `dogs` (id, household_id, name, photo_key)
- `devices` (id, household_id, name, role camera|viewer, model, app_version, apns_token, device_secret_hash, status, last_heartbeat_at, battery, charging, thermal)
- `zones` (id, device_id, kind door|forbidden|bed, polygon jsonb in normalized coordinates)
- `events` (id, household_id, device_id, type, state, started_at, ended_at, confidence, clip_key, snapshot_key, feedback)
- `daily_summaries` (household_id, date, rest_minutes, bark_count, activity_by_hour jsonb)
- `notification_prefs` (user_id, device_id, event_type, enabled, quiet_start, quiet_end)
- `invites` (token, household_id, expires_at, used_at)

## 10. Privacy and security

- Analysis happens on the device only. Only event clips and snapshots are uploaded.
- WebRTC is encrypted (DTLS-SRTP). LiveKit E2EE comes later.
- Every API route is scoped to the caller's household. Presigned URLs are short-lived.
- Pairing tokens are single-use and short-lived. Devices can be revoked remotely.
- Clips are auto-deleted after 7 days (configurable), and the user can delete all data.
- A clear indicator shows on the camera device when someone is watching or the mic is live, since the camera may also capture people.
- App Store compliance: privacy policy, privacy nutrition label, and permission strings.

## 11. Phases

0. Foundations: repo, XcodeGen, CI, backend skeleton on Railway.
1. Prototype: camera plus one viewer, live view through LiveKit, bark detection, basic push.
2. MVP: households, QR pairing, multiple cameras and viewers, event engine, clips, timeline, notification settings.
3. Vision analysis: dog detection, pose, resting state, zones, daily summary.
4. Custom model: labeled data collection, a Core ML state classifier, and the feedback loop.
5. Product: subscriptions (StoreKit 2), widgets and Live Activity, iPad and Mac viewer.
