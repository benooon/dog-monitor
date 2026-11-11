# Needs validation

## trustProxy: true lets clients choose request.ip, which defeats the per-IP waitlist and invite-code rate limits

`backend/src/app.ts:trustProxy-all-hops:client-controlled-request-ip`

buildApp creates Fastify with trustProxy: true, so Fastify trusts every hop and request.ip is the leftmost X-Forwarded-For entry. That entry is client-controlled whenever the edge proxy appends to an incoming X-Forwarded-For header instead of replacing it. Two in-memory AttemptLimiters key on request.ip: the waitlist sign-up limiter (5 per IP per 10 min, waitlist.ts:61/64) and the invite redemption limiter (10 failures per 10 min, invites.ts:86/87/162). The invite limiter is the only brute-force control on 6-digit pairing codes, and a successful camera redemption returns a deviceSecret for the victim's household. In an independent sandbox run with the production default limiters, rotating the leftmost XFF entry from one socket peer was never limited on /waitlist (15x 202), and invite-code guessing resumed after a block (429, then 404 for each new leftmost value). Exploitability in production depends only on how Railway's edge treats an incoming X-Forwarded-For header, which is not in the repository.

**Claimed root cause:** backend/src/app.ts:81 sets trustProxy: true, which trusts every X-Forwarded-For hop instead of only the single Railway edge hop, so request.ip can be an attacker-supplied leftmost value and the per-IP AttemptLimiter keys become attacker-chosen.

**Trace**
1. entrypoint `backend/src/routes/waitlist.ts:61` (POST /waitlist handler): An anonymous client posts with an arbitrary X-Forwarded-For header; limiter.isBlocked reads request.ip.
2. propagation `backend/src/app.ts:81` (buildApp Fastify options): trustProxy: true makes Fastify (getTrustProxyFn returns always-true) resolve request.ip to the leftmost X-Forwarded-For address.
3. propagation `backend/src/routes/waitlist.ts:64` (POST /waitlist handler): recordFailure is keyed on the spoofed request.ip, so each rotated value starts a fresh bucket.
4. sink `backend/src/pairing/attempt-limiter.ts:14` (AttemptLimiter.isBlocked): The per-key window never reaches maxFailures for rotating keys, so the limit never applies.

**Evidence**
- `backend/src/app.ts:81`: trustProxy: true, with the comment 'trust X-Forwarded-For so request.ip is the client' (line 80). No other proxy configuration exists in the repo; railway.json only sets the Dockerfile build and healthcheck.
- `backend/src/routes/waitlist.ts:61`: Waitlist limiter keyed on request.ip (production default AttemptLimiter(WAITLIST_MAX_PER_IP, WAITLIST_WINDOW_MS) at line 25). Independent run (agents/v1/artifacts/evidence/v1-xff.txt): fixed XFF '192.0.2.200, 198.51.100.20' gave 202x5 then 429x2; rotating '192.0.2.N, 198.51.100.20' from the same socket peer gave 202 on all 15; request.ip resolved to the leftmost 192.0.2.66.
- `backend/src/routes/invites.ts:86`: Invite redemption limiter key is request.ip (default AttemptLimiter(10, 10 min) at line 31; failures recorded at line 162). Independent run: 10 bad camera code guesses with leftmost XFF 203.0.113.1 returned 404x10 then 429; new leftmost values 203.0.113.2-6 each returned 404 (guessing resumed).
- `backend/package-lock.json:3757`: Locked fastify 5.12.8. In this version a numeric trustProxy (e.g. 1) fails closed to the socket peer (node_modules/fastify/lib/request.js getTrustProxyFn), so the hunter's proposed 'trustProxy: 1' fix would key every client on the edge address; verified locally (request.ip = 10.1.2.3). A function trusting only the immediate peer, (addr, i) => i === 0, resolves to the edge-appended rightmost entry (198.51.100.20).

**Blockers**
- Not visible in source: whether Railway's edge proxy appends the connecting client's address to an incoming X-Forwarded-For header (leftmost entry stays client-controlled, so the bypass works) or replaces/strips it (request.ip is the real client and trustProxy: true is safe in this deployment). Also not visible: whether the service is reachable only through that single edge hop.

**Local plan:** Done: agents/v1/artifacts/evidence/v1-xff.txt (backend/test/v1-xff.test.ts via run-backend-check.sh) shows the bypass on /waitlist and /invites/:code/accept with production default limiters. Regression after a fix: replace trustProxy: true with a function that trusts only the immediate peer, e.g. trustProxy: (_addr, i) => i === 0 (or the edge's CIDR if Railway publishes one); do not use trustProxy: 1, which fastify 5.12.8 treats as trust-nothing. Then, with remoteAddress 10.1.2.3 and 'X-Forwarded-For: 203.0.113.N, 198.51.100.9', request.ip must be 198.51.100.9 for every N, the 6th waitlist post must return 429, and the 11th bad invite code must return 429 regardless of N.

**Owner-observed check:** On a staging Railway service only (never production, no brute force): the owner temporarily logs request.ip and the raw x-forwarded-for header for one request, then sends one request from their own machine with 'X-Forwarded-For: 192.0.2.1'. If the logged header is '192.0.2.1, <their public IP>' and request.ip is 192.0.2.1, the edge appends and the finding is exploitable; if the header contains only their public IP and request.ip equals it, the edge replaces the header and the finding does not apply.

## Sandbox (TestFlight) App Store transactions grant production Premium

`backend/src/billing/app-store.ts:transaction-environment-not-checked`

createAppStoreVerifier checks the x5c chain, the signature, the bundle and the product, but never the transaction's environment. AppStoreConfig and the production config have no expected-environment setting. So POST /subscription/apple and POST /app-store/notifications accept an Apple-signed transaction with environment "Sandbox" and give the household Premium. The environment is only stored in households.plan_environment, and nothing reads that column. A local run showed the code path: a Sandbox transaction from the test chain, sent to POST /subscription/apple, returned 200 with plan premium and limits.cameras 4, and the row was stored as plan=premium, planEnvironment=Sandbox. Some deployment facts can be read from the repository. Every build config points at the production backend (ios/project.yml API_BASE_URL in settings.base). HUMAN_TODO also tells the owner to set the sandbox notification URL to that same production host. Sandbox purchases cost nothing. So anyone who can make Apple-signed Sandbox purchases for this bundle, such as a TestFlight tester or a sandbox tester account, can turn on production Premium for free. While the plan is active they can pair up to the Premium camera limit, and those cameras keep working after it lapses (a lapsed plan blocks only new pairings).

**Claimed root cause:** parsePayload reads `environment` (and defaults it to "Production" when it is missing), but verify() never compares it with an expected environment, and AppStoreConfig/loadConfig has no such field. applyTransaction then applies Sandbox transactions exactly like Production ones and only records the value in planEnvironment.

**Trace**
1. entrypoint `backend/src/routes/subscription.ts:66` (POST /subscription/apple): The household owner's client-supplied signedTransaction goes to verifier.verify. The notification route does the same at line 135 for data.signedTransactionInfo.
2. propagation `backend/src/billing/app-store.ts:87` (createAppStoreVerifier.verify): After the chain and signature checks, only bundleId (line 89) and productId (line 90) are compared. Nothing checks environment.
3. sink `backend/src/billing/apply-transaction.ts:28` (applyTransaction): Sets plan premium and planExpiresAt from the transaction, and stores planEnvironment = transaction.environment (line 35) without acting on it.

**Evidence**
- `backend/src/billing/app-store.ts:112`: environment is parsed and defaults to "Production", but nothing enforces it.
- `backend/src/config.ts:133`: The appStore config has bundleId, productIds and rootFingerprints, with no expected environment.
- `backend/src/billing/plans.ts:16`: effectivePlan depends only on planExpiresAt. planEnvironment is never read anywhere in backend/src.
- `ios/project.yml:82`: API_BASE_URL is set once in settings.base to the production Railway host, so every build of this app, TestFlight builds included, talks to the production backend.
- `docs/HUMAN_TODO.md:18`: Tells the owner to set both the production and the sandbox App Store Server Notifications URL to the same production /app-store/notifications endpoint.
- `backend/test/subscription.test.ts:54`: The existing test fixture uses environment "Sandbox", and the route tests expect it to grant premium. Accepting Sandbox is the tested behavior today.

**Blockers**
- Whether people who have not paid can get genuine Apple-signed Sandbox transactions for bundle com.benooon.dogmonitor is a distribution fact outside the repository. That would mean public-link or external TestFlight testers, or sandbox tester accounts given to non-owners. Today the TestFlight workflow is blocked in docs/BACKLOG.md, so no TestFlight build may exist yet. The repository already answers the other half: those builds would use the production backend.

**Local plan:** Already run (evidence agents/v2/artifacts/evidence/sandbox-env.txt). backend/test/v2-sandbox-env.test.ts uses a verifier built like the production config (bundleId, productIds, rootFingerprints only) and a transaction from the test chain with environment "Sandbox" and appAccountToken = the dummy household id. POST /subscription/apple returned 200 {plan: premium, limits.cameras: 4}, and the households row showed plan=premium, planEnvironment=Sandbox. After a fix, the same test with an expected environment of Production should get 400 {error: wrong_environment} and leave the plan free.

**Owner-observed check:** Owner check, read-only: (1) In App Store Connect → TestFlight, is there an external group or a public link for com.benooon.dogmonitor, and how many testers outside the household or team does it have? (2) Are sandbox tester accounts (Users and Access → Sandbox) shared with anyone besides the owner? (3) Run a read-only query on the production database: SELECT count(*) FROM households WHERE plan_environment = 'Sandbox' AND plan_expires_at > now(). Any rows mean sandbox transactions are already granting production Premium.

## Member removal and camera revocation do not evict participants already in the LiveKit room

`backend/src/live/livekit.ts:no-participant-eviction-on-revocation`

POST /cameras/:id/live-token gives a household member a 10-minute LiveKit token for room camera-<deviceId>. The token can subscribe to the camera's video and audio and publish microphone audio, which the camera plays aloud as talk-back. When the owner removes that member (DELETE /household/members/:userId) or revokes a device (POST /devices/:id/revoke), the backend only changes database rows. It never calls the LiveKit RoomService (removeParticipant, updateParticipant or deleteRoom), even though livekit-server-sdk, already a dependency, exports RoomServiceClient. The iOS viewer stays in the room while the connection is up and does not re-check membership after connecting. If LiveKit keeps a connected participant in the room past the token's expiry, or keeps refreshing that participant's token, a removed member keeps watching the household's camera and can keep talking into the home. This lasts until the connection drops and the client has to fetch a new token from the backend, which then answers 403. A revoked camera can likewise keep publishing into its room. Source alone cannot say how long this lasts. That depends on LiveKit server behavior.

**Claimed root cause:** backend/src/live/livekit.ts mints room tokens (10-minute TTL, with a comment that the SDK refreshes them in-room), but nothing in backend/src ends a live session. RoomServiceClient is never used, and DELETE /household/members/:userId (households.ts:94-122) and POST /devices/:id/revoke (devices.ts:151-163) only update database rows. Revoking access therefore relies only on token expiry, and token expiry does not cover a connection that is already established.

**Trace**
1. entrypoint `backend/src/routes/live.ts:31` (POST /cameras/:id/live-token): A signed-in household member, scoped by requireHousehold to an active camera in their household, gets a viewer token for room camera-<deviceId>
2. propagation `backend/src/live/livekit.ts:54` (viewerToken grant): Grant: canSubscribe true, canPublish true with source MICROPHONE (talk-back into the home), roomJoin on the camera's room
3. propagation `backend/src/live/livekit.ts:21` (LIVE_TOKEN_TTL_SECONDS): The 10-minute TTL only limits when a client can connect. The comment on line 20 says the SDK refreshes the token in-room, so the TTL is not a session cap.
4. sink `backend/src/routes/households.ts:114` (DELETE /household/members/:userId): In a transaction, removal deletes the membership row, revokes the member's own device rows and deletes their notification prefs. No LiveKit RoomService call removes the member's live participant.

**Evidence**
- `backend/src/live/livekit.ts:20`: Comment: "Tokens only need to stay valid long enough to connect; the SDK refreshes them in-room."
- `backend/src/routes/devices.ts:159`: POST /devices/:id/revoke sets status revoked and clears the secret hash and APNs token. It does not touch LiveKit.
- `backend/src/routes/live.ts:50`: Revocation is only enforced when a token is minted (device_revoked 409, or 403 from requireHousehold after removal). A participant who is already connected is never re-checked.
- `ios/App/Viewer/LiveViewModel.swift:168`: The viewer loop stays in the room while connectionState != .disconnected. It only fetches a new backend token, which is where membership gets re-checked, after a disconnect.
- `backend/package.json:27`: livekit-server-sdk ^2.19.3 is a dependency and ships RoomServiceClient (node_modules/livekit-server-sdk/dist/RoomServiceClient.d.ts), but grep finds no use of RoomServiceClient, removeParticipant or deleteRoom anywhere in backend/src

**Blockers**
- How long a removed participant stays in the room depends on the LiveKit server, outside this repository: whether a connected participant is disconnected when its JWT expires, and whether LiveKit Cloud pushes refreshed tokens to that participant after the backend stops minting. The sandbox has no LiveKit server binary and no network, so this cannot be observed offline.

**Local plan:** On a workstation with no external network, run a pinned LiveKit OSS server in dev mode on loopback (livekit-server --dev, keys devkey/secret). Point the backend's LIVEKIT_URL/API_KEY/API_SECRET at it and start the backend against a throwaway Postgres. Create a household with owner U1, member U2 and camera D1. With livekit-client or the Go/Node test client, connect D1 using POST /device/live-token and publish a synthetic video track. Connect U2 using POST /cameras/D1/live-token. Call DELETE /household/members/U2 as U1 and confirm that U2's next POST /cameras/D1/live-token returns 403. Then poll RoomServiceClient.listParticipants('camera-D1') every 60 s for 15 minutes, which is more than the 10-minute TTL. Record whether U2's viewer identity is still listed and still subscribed to D1's track, and whether U2 can still publish a microphone track. Repeat with POST /devices/D1/revoke and check whether D1's identity stays published. Tear everything down afterwards.

**Owner-observed check:** Owner-run, in a staging LiveKit Cloud project and a staging backend only, never production: connect a test member as a viewer of a test camera, remove that member with DELETE /household/members/:userId, and watch the room's participant list in the LiveKit dashboard for more than 10 minutes to see whether the member's viewer:<userId>:* participant is still connected and subscribed. Do the same for a revoked test camera with POST /devices/:id/revoke.
