# Things only the owner can do

Agents add items here when they are blocked. The owner checks items off.

- [ ] **Apple Developer Program** ($99/year), needed for TestFlight, push notifications and Sign in with Apple on a real device.
- [ ] **App Store Connect API key**: create it under Users and Access → Integrations → Keys (App Manager role). Add GitHub repo secrets `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the .p8 contents), plus `APPLE_TEAM_ID`. Then remove `[blocked]` from the TestFlight task in BACKLOG.md.
- [ ] Create the app record in App Store Connect with bundle id `com.benooon.dogmonitor`.
- [ ] **APNs key** (.p8, Keys → Apple Push Notifications service). Set it as Railway env vars `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_KEY_P8`.
- [ ] **LiveKit Cloud** project (free tier is fine to start). Set Railway env vars `LIVEKIT_URL`, `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`.
- [ ] **Railway**: new project → deploy from GitHub repo `benooon/dog-monitor`, root directory `backend`, add the PostgreSQL plugin, set the env vars from `backend/.env.example`. Railway then redeploys automatically on every push to main.
- [ ] **Cloudflare R2** (or another S3-compatible bucket) for clips. Set the `S3_*` env vars on Railway.
- [ ] **GitHub Actions minutes:** macOS runners cost 10x minutes on private repos (the free plan has 2,000 min/month, which is about 200 macOS minutes). Either make the repo public (Actions are free) or add a payment method / spending limit.
- [ ] **Railway backend env**: besides `DATABASE_URL`, set `JWT_SECRET` (`openssl rand -hex 32`) and `APPLE_AUDIENCES=com.benooon.dogmonitor`. Then send agents the public Railway URL (or put it in `ios/project.yml` → `API_BASE_URL`), which currently defaults to `http://localhost:3000`.
- [ ] Enable the **Sign in with Apple** capability on the App ID `com.benooon.dogmonitor` (the app already declares the entitlement).
