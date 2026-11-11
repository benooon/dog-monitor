# Privacy: what Dog Monitor does with data

Source of truth for the privacy policy, the App Store privacy label and the legal review. It describes what the code does **today** (2026-11-11). If the code changes, change this file in the same commit. Do not claim a protection that is not listed under "Protections that exist".

## Who is involved

| Role | Who |
|---|---|
| Controller / operator | The owner of Dog Monitor (company details: see `HUMAN_TODO.md`, not yet filled in) |
| Processors | Railway (API + Postgres), the S3-compatible bucket provider (Cloudflare R2 or Railway bucket), LiveKit Cloud (live video relay), Apple (Sign in with Apple, push, subscriptions) |
| Data subjects | The signed-in household members, and anyone the camera happens to see or hear |

## Data map

| Data | Why | Where it lives | How long | Who can see it |
|---|---|---|---|---|
| Apple user id (`apple_sub`) and name (only if Apple shares it; email is not requested or stored) | Sign in | Postgres `users` | Until the account is deleted | Backend only |
| Household name, members and roles | Family sharing | Postgres | Until the account / household is deleted | Household members |
| Dog name, life stage, traits, alert style, dog photo (JPEG) | Personalisation, notifications | Postgres `dogs`, `dog_photos` | Until the dog or account is deleted | Household members |
| Camera and viewer phones: name, model, app version, push token, battery, charging, thermal state, dog state, time zone, last-seen time | Pairing, push, "camera offline / low battery" alerts | Postgres `devices` | Until the account is deleted or the phone is removed (removal clears the push token) | Household members (name, status) |
| Zones drawn on the camera view (door, forbidden, bed) | Event detection | Postgres `zones` | Until the camera is deleted | Household members |
| Events: type, dog state, start/end, confidence, right/wrong feedback | Timeline, notifications | Postgres `events` | 365 days (`EVENT_RETENTION_DAYS`, min 30), deleted daily once their files are gone | Household members |
| Daily summaries: rest minutes, bark count, activity per hour, minutes per dog state | Daily summary | Postgres `daily_summaries` | 365 days (`EVENT_RETENTION_DAYS`), deleted daily | Household members |
| Event snapshots (JPEG) and clips (video **with audio** when microphone is allowed) | Show what happened | Bucket, keys on `events` | `CLIP_RETENTION_DAYS` (default 7 days), deleted daily. Labeled clips of households that opted in to "help improve detection" are kept up to 90 days | Household members through short-lived links (10 min) |
| Live video and audio, and talk-back audio | Watch live | Streamed through LiveKit Cloud; not stored by Dog Monitor | Not stored | Household members who press "watch live" |
| Notification settings (per event type, quiet hours) | Pushes | Postgres | Until the account is deleted | The user |
| Live Activity push tokens | Dynamic Island updates | Postgres | Until the activity ends or the account is deleted | Backend |
| Subscription: plan, product id, expiry, original transaction id, environment | Premium | Postgres `households` | Until the household is deleted | Backend |
| Invites: token, 6-digit code, expiry | Add family | Postgres | Until used / expired / household deleted | Backend |
| Server logs: request method, URL path (invite tokens and query strings removed), status, errors. The app does not log IP addresses; Railway's own proxy logs may | Operation and security | Railway logs | Set by Railway (not configured by us) | Operator |

## Analysis happens on the phone

Bark detection, dog detection, motion and zone logic run on the camera phone. Only the events they produce, a snapshot and a clip go to the server. No third-party analytics or crash-reporting SDK is in the app or backend (checked 2026-11-11: the only SDKs are LiveKit and Apple frameworks). No advertising, no tracking, no data sale or sharing for advertising. Therefore no App Tracking Transparency prompt.

## People other than the owner

A camera can see and hear guests, dog walkers and cleaners. Today: the camera screen shows how many people are watching and when someone is talking through the phone (SPEC §10). There is no sign-off or notice text for the people being recorded, and the owner is not told to inform them. Tracked in `LEGAL_LOG.md` and `BACKLOG.md`.

## Protections that exist

- Traffic to the API, LiveKit and the bucket uses TLS. Live video uses WebRTC (DTLS-SRTP) between the phones and LiveKit.
- Every API route is scoped to the caller's household; presigned media links are short-lived (upload 15 min, download 10 min).
- Device secrets are stored hashed; devices can be revoked; removing a member revokes their phones and clears push tokens.
- Training data sharing is **off by default** and chosen by the household owner.
- Account deletion: `DELETE /me`; household deletion: `DELETE /household` (owner). In-app: "Delete account" in Household settings and on the create-household screen. The household-deletion button is not built yet.
- Data export: "Download my data" in Household settings (`GET /me/export`, JSON without clips).
- Request logs carry only method and path; invite tokens, query strings and IP addresses are not logged by the app.

## Protections that do NOT exist yet (never claim these)

- **End-to-end encryption.** LiveKit Cloud can technically see the live stream. E2EE is a backlog task.
- **A specific server region.** Railway, the bucket and LiveKit Cloud regions are not pinned or documented. Data may be processed outside the EU and Israel.
- **Encryption of the database or bucket beyond what the providers do by default.**
- **Revocation of the Sign in with Apple token on account deletion.**
