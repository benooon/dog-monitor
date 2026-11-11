# Architecture (dog-monitor, run-1, quick profile)

## Product and principals
Dog Monitor turns a spare iPhone into a dog camera. Principals:
- **Anonymous internet client**: may call public routes (`/health`, `/`, `/join`, `/he/join`, static landing assets, `POST /waitlist`, `GET|POST /waitlist/unsubscribe`, `/.well-known/apple-app-site-association`, `GET /invite/:token` HTML page, `POST /auth/apple`, `POST /app-store/notifications`).
- **Signed-in user** (Sign in with Apple → our HS256 JWT, `Authorization: Bearer`): owner or member of at most one **household** (`household_members`). Members watch live, see the timeline/media, set their own notification prefs. Owners also create invites, rename/delete the household, manage dogs/devices, buy Premium.
- **Camera device** (`Authorization: Device <uuid>:<secret>`, secret hashed in `devices.device_secret_hash`): created by redeeming an invite as a camera; posts events, zones, summaries, uploads media, gets a LiveKit publisher token, and joins the realtime WebSocket.
- **Apple** (App Store Server Notifications V2, signed JWS) and **operator** (`ADMIN_TOKEN` for `GET /waitlist/stats`, env secrets).
Protected resources: other households' video (LiveKit rooms), clips/snapshots (S3-compatible bucket, presigned URLs), event timeline, dog profile and photo, household membership, Premium entitlement, waitlist emails, push tokens.

## Stack and deployment
Node 22 + TypeScript, Fastify 5, Drizzle ORM on PostgreSQL, Vitest. Deployed to Railway from `backend/Dockerfile` (`railway.json`); TLS terminates at Railway's proxy and `trustProxy: true` is set (`backend/src/app.ts`). LiveKit Cloud for live video (server mints tokens, `backend/src/live/livekit.ts`), APNs token auth, S3/R2 storage. iOS app (Swift 6) with a Linux-buildable core package `ios/Packages/DogMonitorCore` holding the API client; credentials on the phone live in the Keychain (`ios/App/KeychainStore.swift`, `SecureStore.swift`). No Swift toolchain in this sandbox: Swift is source-only. Backend tests run offline with a private Postgres inside the parent's sandbox (`/srv/security-audit/tools/run-backend-check.sh`).

## Entry surfaces and important paths
- Auth: `backend/src/routes/auth.ts` (Apple identity token + nonce → user upsert → JWT), `backend/src/auth/{apple,jwt,plugin}.ts`. Training export token = same JwtService with a 1 h TTL (`backend/src/routes/training.ts`).
- Household scope: `backend/src/households/scope.ts` (`requireHousehold`, `requireOwner`), used by `routes/{households,dogs,devices,invites,timeline,notification-prefs,live,live-activities,summaries,subscription,media,training}.ts`.
- Pairing: `backend/src/routes/invites.ts` (token or 6-digit code, 10 failures/10 min in-memory limiter, accept as member or camera, plan camera limit), `backend/src/pairing/secrets.ts`.
- Device routes: `backend/src/auth/device-plugin.ts` + `routes/{events,zones,media,summaries,live,device-self}.ts`; media keys must start with `eventMediaPrefix(household, device, event)`.
- Media: `backend/src/routes/media.ts` + `backend/src/storage/storage.ts` (presigned PUT/GET), retention job `storage/retention.ts`.
- Realtime: `backend/src/routes/realtime.ts` + `realtime/hub.ts` (WebSocket, heartbeats, presence, viewer counts); LiveKit room tokens in `routes/live.ts`.
- Billing: `backend/src/routes/subscription.ts`, `billing/app-store.ts` (x5c chain to pinned Apple root), `billing/apply-transaction.ts`.
- Public: landing (`routes/landing.ts`, `landing/*`), waitlist (`routes/waitlist.ts`), app links (`routes/app-links.ts`), health.

## Trust boundaries and strongest visible control
1. Internet → user session: Apple JWKS verification with audience + nonce; HS256 JWT with issuer/audience/alg pinned.
2. User → household data: `requireHousehold` resolves the caller's single membership; per-route queries must filter by that household.
3. Internet → camera identity: invite token/code redemption; device secret hash compare (`secretMatches`, timing-safe).
4. Camera → other cameras/households: `request.device.householdId` / `deviceId` scoping in device routes; media key prefix check.
5. Viewer → bucket objects: server-side presign only after the event is found in the caller's household.
6. Apple → entitlement: signed transaction chain verification; `originalTransactionId` bound to one household.
7. Operator secrets: env only (`backend/.env.example`), admin bearer compare.

## Prior coverage
No prior run or ledger exists for this repository. Nothing is carried or excluded.

## Companion selection
- WEB-PROTOCOL-AND-AUTH.md: JWT session tokens, Sign in with Apple, scoped export tokens.
- DATA-ISOLATION-AND-LIFECYCLE.md: multi-household tenancy and presigned media links.
- PROTOCOLS-RPC-AND-MESSAGING.md: WebSocket channel identity for cameras and viewers.
- DESKTOP-MOBILE-AND-LOCAL-IPC.md: Keychain storage of the session JWT and device secret on the phone.
Not selected: CLIENT-SIDE (the landing script has no auth state or DOM sinks from input; covered by the public-surface unit), RESOURCE-EXHAUSTION (no unit in quick profile; noted as a gap), SUPPLY-CHAIN/CLOUD (CI and Railway config out of scope for this run), MEMORY-SAFETY, AI-AND-LLM (not applicable).
