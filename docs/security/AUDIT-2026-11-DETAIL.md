# Findings detail (medium and above)

## Refunded App Store subscription can be restored by replaying the pre-refund signed transaction

`backend/src/billing/apply-transaction.ts:revocation-not-persisted-replay`, medium, fixed in `d7d94fd`

**Trace**
1. entrypoint `backend/src/routes/subscription.ts:47` (POST /subscription/apple (requireOwner)): A signed-in household owner submits signedTransaction, which can be any Apple-signed JWS, however old
2. propagation `backend/src/routes/subscription.ts:66` (verifier.verify): Checks the x5c chain, the signature, the bundle and the product. Nothing checks signedDate, purchaseDate or revocation state. The appAccountToken check (line 71) and the cross-household check (lines 75-86) both pass for the owner's own household.
3. propagation `backend/src/billing/apply-transaction.ts:12` (applyTransaction revocation branch): An earlier REFUND notification (POST /app-store/notifications, subscription.ts:160) set plan=free and planExpiresAt=null and stored nothing about the revocation
4. sink `backend/src/billing/apply-transaction.ts:28` (applyTransaction premium update): Because current.expiresAt is null, extendsPremium is true (line 26), so the replayed transaction writes plan=premium and planExpiresAt = its original expiresDate

**Evidence**
- `backend/src/billing/apply-transaction.ts:15`: The revocation branch only sets { plan: "free", planExpiresAt: null }. The revoked state and its time are lost.
- `backend/src/billing/apply-transaction.ts:26`: extendsPremium = !current?.expiresAt || transaction.expiresAt > current.expiresAt is true after a refund, so the guard on line 27 lets the replay through
- `backend/src/billing/app-store.ts:96`: parsePayload reads only transactionId, originalTransactionId, productId, bundleId, environment, expiresDate, revocationDate and appAccountToken. Without purchaseDate or signedDate, an old transaction cannot be told apart from a new one.
- `agents/v3/artifacts/evidence/v3-refund-replay.txt:1`: Independent sandboxed reproduction through the real routes and verifier, for both configured products. Purchase at T0, REFUND at T0+10d, replay of the saved JWS at T0+20d: 200 and premium again, with cameras limit 4.

**Principal:** A household owner who bought Premium, kept the StoreKit signed transaction, and then got a refund from Apple

**Input:**
- `POST /subscription/apple {"signedTransaction": "<the same JWS posted at purchase, byte for byte>"} sent after the REFUND notification was applied`

**Bounded instructions:**
1. Add test/v3-refund-replay.test.ts (in the evidence file) to a copy of backend/ and run it with /srv/security-audit/tools/run-backend-check.sh. It uses a private Postgres and the repo's test App Store chain fixtures, and backend/src is unmodified.
2. T0: sign in, create a household, and POST /subscription/apple a signed transaction (appAccountToken = household id, expiresDate = T0+365d or T0+30d). Keep the JWS.
3. T0+10d: POST /app-store/notifications with a REFUND notification whose signedTransactionInfo is the same transaction plus revocationDate. GET /subscription now shows free.
4. T0+20d: POST /subscription/apple again with the saved pre-refund JWS, then GET /subscription.

**Observed:** Yearly: purchase gave 200 premium until 2028-02-29. After the REFUND, plan was free with expiresAt null and cameras limit 1. The replay returned 200 premium until 2028-02-29 with cameras limit 4, and GET /subscription still showed premium. Monthly behaved the same: the replay restored premium until 2027-03-31.

**Invariant:** Once Apple reports a subscription's transaction as refunded or revoked, the server must not grant premium again from that transaction or any earlier one of the same originalTransactionId. Only a genuinely newer purchase or renewal (purchaseDate after the revocation) may restore premium.

**Conditions**
- authentication_level: Signed-in household owner (requireOwner on POST /subscription/apple)
- data_state: The owner kept a copy of the signed transaction JWS their app posted at purchase, for example by capturing their own app's HTTPS traffic through a user-installed CA. Apple then refunded or revoked it, and the REFUND/REVOKE notification was applied.
- timing_dependency: The replay must happen before the transaction's original expiresDate, and while the JWS's x5c certificates are still within their validity window (verifyPayload checks the validity window against the current time)
- system_configuration: Only matters when ENFORCE_PLAN_LIMITS is on. When it is off, every household gets the full camera limit anyway (plans.ts cameraLimit).

**Remediation:** Persist the revocation and refuse to grant premium again from any transaction of the same subscription bought at or before it. Add a nullable households.planRevokedAt (or a revoked_transactions table keyed by originalTransactionId) with a migration. Set it in the revocation branch and keep planOriginalTransactionId. Parse purchaseDate in parsePayload and require it. In applyTransaction, when originalTransactionId matches the household's subscription and a revocation is recorded, ignore transactions whose purchaseDate is at or before planRevokedAt. Clear planRevokedAt when a genuinely newer transaction grants premium. Optionally confirm state with the App Store Server API (Get Transaction Info / Get All Subscription Statuses) before granting from a client-posted transaction. Regression test: purchase, REFUND, replay the original JWS, expect the plan to stay free; a new renewal with a later purchaseDate still grants premium.

## Invite-code brute-force limiter is check-then-record, so concurrent guesses bypass it

`backend/src/routes/invites.ts:invite-accept-limiter-check-then-record-race`, medium, fixed in `d7d94fd`

**Trace**
1. entrypoint `backend/src/routes/invites.ts:59` (POST /invites/:token/accept): Public route: no auth for as=camera, any valid user JWT for as=member; the :token param may be a 6-digit code
2. propagation `backend/src/routes/invites.ts:87` (limiter.isBlocked(limiterKey)): Synchronous read of failures recorded so far; requests already in flight all see the same pre-burst count and continue
3. propagation `backend/src/routes/invites.ts:110` (db.transaction: UPDATE invites SET used_at WHERE code = param AND unused AND unexpired RETURNING): Each in-flight request evaluates its guess against all active invites (code param selected at line 103/115)
4. sink `backend/src/routes/invites.ts:162` (limiter.recordFailure(limiterKey) on 404): Failure is recorded only after the guess was evaluated; a hit instead returns 201 with deviceSecret (line 157) or 200 household membership (line 133)

**Evidence**
- `backend/src/pairing/attempt-limiter.ts:14`: isBlocked only reads recent failures; recordFailure (line 18) is a separate later call, there is no atomic check-and-reserve
- `backend/src/routes/invites.ts:31`: Production default limiter is new AttemptLimiter(10, 10 * 60 * 1000) keyed by request.ip (line 86); no other throttle is registered on this route (backend/src/app.ts:98)
- `backend/src/pairing/secrets.ts:10`: Invite codes are randomInt(0, 1_000_000), a 10^6 space; invites live 10 minutes (INVITE_TTL_MS line 29)
- `backend/src/routes/invites.ts:157`: Successful camera redemption returns a fresh device secret bound to the invite's household
- `agents/v5/artifacts/evidence/v5-invite-limiter-race.txt:1`: v5 independent sandboxed reproduction with the production-default limiter: 101 concurrent accepts from one address gave {404: 100, 201: 1}; the real code redeemed with a deviceSecret for the victim household; the next request got 429

**Principal:** Unauthenticated client at a single address sending many concurrent POST /invites/<6-digit code>/accept requests with {"as":"camera"}

**Input:**
- `101 concurrent POST /invites/<code>/accept {"as":"camera","deviceName":"attacker"}: codes 000000..000100 excluding the real code, plus the real active code last`

**Bounded instructions:**
1. In the sandbox, build the app with buildTestApp(h) and no inviteLimiter override, so the production default AttemptLimiter(10, 600000) is used
2. Sign in a victim owner, create a household, and POST /invites to get an active 6-digit code
3. Send the 101 accepts at once with Promise.all(app.inject(...)) from the same client address (no X-Forwarded-For)
4. Count status codes, check the real-code response for deviceSecret and householdId, then send one more bad guess

**Observed:** V5_BURST {"burst":101,"statusCounts":{"201":1,"404":100},"realCodeStatus":201,"realCodeHousehold":true,"deviceSecretReturned":true,"afterBurstStatus":429} - 100 wrong guesses were evaluated under a 10-failure limit and the real code redeemed as a camera in the victim household; only the request after the burst was blocked.

**Invariant:** No client may have more than 10 invite-code guesses evaluated per 10 minutes; an attempt must be counted atomically, before the code is looked up, regardless of how many requests are in flight.

**Conditions**
- authentication_level: None for camera redemption; for member redemption any Sign in with Apple account not already in a household
- data_state: At least one unused, unexpired invite code exists (10-minute TTL); each evaluated wrong guess hits with probability about (active codes)/10^6
- timing_dependency: Guesses must be in flight concurrently; the number evaluated per window is bounded by connection and server concurrency, not by the limiter

**Remediation:** Count the attempt atomically before evaluating the guess: replace isBlocked/recordFailure with a synchronous tryAcquire that checks and records in one step (no await between them), call it before authentication and the DB transaction for code-shaped params, and drop the later recordFailure. Because the limiter is per-process and per-address, also add a global cap on failed code redemptions across all clients (or persist attempts in Postgres) so throughput cannot be scaled by instances or addresses. The X-Forwarded-For keying issue noted by the hunter is a separate root cause and is not fixed by this change.

## Training export key is a full owner session token that can add members and renew itself

`backend/src/routes/training.ts:export-token-unscoped-session-jwt`, medium, fixed in `d7d94fd`

**Trace**
1. entrypoint `backend/src/routes/training.ts:32` (POST /training/export-token): An owner session (or an existing export key) asks for a one-hour export key
2. propagation `backend/src/routes/training.ts:34` (POST /training/export-token): opts.jwt.issue({ userId }, EXPORT_TOKEN_TTL_SECONDS): only the TTL changes, no scope or audience
3. propagation `backend/src/auth/jwt.ts:22` (JwtService.issue): Signs an empty payload with the same sub, iss 'dog-monitor' and aud 'dog-monitor-app' as the session token
4. propagation `ios/App/Household/HouseholdView.swift:201` (HouseholdView training section): The key goes on UIPasteboard.general. docs/TRAINING.md says to paste it into DOGMONITOR_TOKEN on a Mac
5. propagation `backend/src/auth/plugin.ts:22` (app.authenticate): Any token that passes JwtService.verify becomes request.user, with no scope check
6. sink `backend/src/routes/invites.ts:36` (POST /invites): authenticate + requireHousehold + requireOwner accept the export key. The invite it creates lets an outsider join as a persistent member

**Evidence**
- `backend/src/auth/jwt.ts:34`: verify checks only iss, aud and HS256 and returns { userId: sub }. Nothing tells an export key from a session
- `backend/src/routes/training.ts:31`: The comment says the key exists so the long-lived session never leaves the phone, which means it should be narrower
- `backend/src/routes/auth.ts:64`: The session token comes from the same jwt.issue call, with the default TTL (JWT_TTL_SECONDS, 30 days, config.ts:65)
- `scripts/export-training-data.mjs:17`: The key is read from the DOGMONITOR_TOKEN env var on a desktop machine and is only needed for GET /training/labeled
- `agents/v7/artifacts/evidence/v7-export-token-scope.txt:1`: Independent local reproduction: the decoded export token has the same claim set, aud, iss and sub as a session. Using only the export key, GET /me returned 200 with role owner, POST /invites 201, PATCH /household rename 200 and POST /training/export-token 200. An outsider accepted the invite as a member (200) and could then read the household (200, 2 members)

**Principal:** Someone who holds only the owner's one-hour training export key

**Input:**
- `Authorization: Bearer <export token from POST /training/export-token>; GET /me; POST /invites; PATCH /household {"name":"Renamed by export key"}; POST /training/export-token`
- `Attacker's own session: POST /invites/<token>/accept {"as":"member"}; GET /household`

**Bounded instructions:**
1. Run test/v7-export-token.test.ts against a disposable copy of backend/ with a private loopback Postgres (run-backend-check.sh sandbox, no external network)
2. Sign in as the owner, POST /households, PATCH /household {shareTrainingData:true}, POST /training/export-token, and decode the session and export JWTs
3. With only the export token: GET /me, POST /invites, PATCH /household (rename), POST /training/export-token
4. Sign in as a second user, accept the invite as a member, then GET /household

**Observed:** Both JWTs have the claim set aud,exp,iat,iss,sub with aud=dog-monitor-app, iss=dog-monitor and the same sub. With the export token: GET /me 200 (role owner), POST /invites 201, PATCH /household 200 (name changed), POST /training/export-token 200. The outsider's accept returned 200 {role: member}, and their GET /household returned 200 with the renamed household and 2 members.

**Invariant:** An export key works only on GET /training/labeled for the household it was issued for, using its own audience (for example 'dog-monitor-training-export') or a scope claim. app.authenticate rejects it on every other route, including POST /training/export-token.

**Conditions**
- data_state: The household owner has turned on training data sharing (shareTrainingData) and generated an export key
- user_interaction: The attacker gets the export key within its one-hour lifetime, for example from the general pasteboard or Universal Clipboard, shell history or environment, or a compromised machine running the export script
- authentication_level: The attacker needs only the export key, plus any Apple account to accept the invite and keep access

**Remediation:** Give export keys their own audience (or a scope claim). app.authenticate verifies the session audience only. Only GET /training/labeled accepts the export audience, and it still applies requireHousehold, requireOwner and the opt-in check. POST /training/export-token requires a real session, so an export key cannot mint another one. Add regression tests that an export key gets 401 on GET /me, POST /invites, PATCH /household and POST /training/export-token.
