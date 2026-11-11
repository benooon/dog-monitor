# Security audit, November 2026, run 2 (gaps from run 1)

## Run
- **Profile:** quick, scoped to the four units run 1's critic deferred (`AUDIT-2026-11.md`, "Coverage"): pre-auth and low-privilege resource use, household membership races, CI workflow and `ci-results` trust, iOS deep links and push routing. Partial coverage, not a full pass.
- **Source ref:** `09c5cdd` (clean). Method: vendored `security-audit` skill, one hunter per unit (4), then the coordinating agent re-read every candidate's source path before fixing it.
- **Execution:** hunters were source-only. Fixes were checked with the repo's own vitest suite against a throwaway local Postgres in the session workspace (normal dev workflow, not the skill's isolated sandbox). The camera-limit race was reproduced by removing the fix: 5+ of 8 concurrent accepts succeeded against a limit of 4. No deployed service was contacted.
- **Prior run:** `AUDIT-2026-11.md` (`cd2dc61`). Its four confirmed findings were not re-hunted.

## Confirmed and fixed

| Severity | Finding | Where | Fix |
|---|---|---|---|
| medium | `/ws` accepted 100 MiB frames (ws default) and ran every message concurrently with no rate limit: any signed-in user could exhaust memory or the Postgres pool for everyone | `app.ts` websocket register, `routes/realtime.ts` message handler | `8481d2e`: `maxPayload` 4 KiB, per-socket token bucket (burst 20, 5/s, close 1008), messages handled in order |
| medium | Concurrent invite accepts bypassed the camera and member limits (count-then-insert in READ COMMITTED, no lock); with `ENFORCE_PLAN_LIMITS` a free household could pair N cameras | `routes/invites.ts` accept transaction | `8481d2e`: lock the household row (`FOR UPDATE`) before counting; same in `POST /devices` |
| low | One user could end up in two households (create + accept race); scope then flipped between them and `DELETE /me` could fail | `db/schema.ts` household_members, `routes/households.ts`, `routes/invites.ts` | `8481d2e`: unique index on `household_members.user_id` (migration 0013 drops race leftovers), 23505 → 409 `already_in_household` |
| low | A socket closed during setup left its `RealtimeSessions` entry forever (memory growth by connect-and-close) | `routes/realtime.ts` close handler | `8481d2e`: untrack after setup finishes |
| low | No cap on dogs per household; each can store a 512 KiB photo in shared Postgres | `routes/dogs.ts` | `8481d2e`: `LIMITS.dogsPerHousehold = 10`, locked count |
| low | `AttemptLimiter` never evicted one-off keys (rotating or spoofed IPs grow the map) | `pairing/attempt-limiter.ts` | `8481d2e`: sweep expired keys once per window |
| low | Fastify `requestTimeout` 0 (slow bodies hold sockets) | `app.ts` | `8481d2e`: 30 s |
| medium | Build jobs ran third-party code (npm scripts, SPM, brew) with a `contents: write` token persisted by checkout: a compromised dependency could push to `main` or forge `ci-results` (hide a red iOS build via `ios-sha.txt` / `ios-result.txt`) | `.github/workflows/ci.yml` permissions, checkouts | `2b693e4`: workflow token read-only, write only in `report`, `persist-credentials: false` on build checkouts; `report` publishes only for `main` |

## Open (in BACKLOG)
- Camera `POST /events` and escalation `PATCH` have no per-device rate limit (DB growth, push volume on the shared APNs key).
- `DELETE /household` reads media keys before its transaction; a clip uploaded in between stays in the bucket (erasure gap).
- Invite 6-digit codes have no unique constraint among unused invites (rare clash joins the wrong household).
- iOS: an invite link pre-fills the join form, but the user never sees which household they are joining. Low: joining gives the victim access to the attacker's cameras, not the reverse.
- Needs validation (owner): `trustProxy: true` (existing lead) and whether branch protection lets the Actions token push to `main` (HUMAN_TODO).

## Checked and held
- `/auth/apple`: input caps, RS256 only, cached JWKS (no fetch per request). App Store notifications: size cap, pinned root before signature checks.
- Invite tokens are single-use under concurrency (atomic `UPDATE … RETURNING`). `DELETE /household` vs concurrent accept is serialised by the FK lock.
- CI: no `pull_request`/`pull_request_target` triggers, commit message reaches the shell only as a quoted env var, the token is masked and never in published logs.
- iOS: `dogmonitor://` is not registered; links never pair a camera or change the server; push snapshot download sends no credentials and requires https; notification routing only opens cameras in the user's own household.
