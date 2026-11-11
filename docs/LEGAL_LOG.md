# Legal and privacy log

Weekly review by the legal agent. I am not a licensed lawyer: anything that needs one is in `HUMAN_TODO.md` → Legal. Risks: High / Medium / Low.

## 2026-11-11 (first review)

**What the app does with data:** see `docs/PRIVACY.md` (new). Accounts via Sign in with Apple, household data in Postgres on Railway, clips and snapshots in an S3 bucket (7 days), live video through LiveKit Cloud (not stored), Apple push and StoreKit. No analytics or crash SDKs. On-device analysis.

**Fixed this week**
1. Added `DELETE /me` (backend, tested): deletes the account, phones and push tokens, and for a lone owner the whole household with events, summaries and stored files.
2. Wrote `docs/PRIVACY.md` (true data map and a list of protections that do not exist), English and Hebrew privacy policy and terms (drafts in `docs/legal/`), in-app notice texts, and a draft App Store label (`docs/APP_STORE_PRIVACY.md`).
3. Microphone usage string now says clips include sound (English and Hebrew).
4. Vendored the `legal` and `gdpr-compliant` skills.

**Open risks**
- **High:** No in-app account deletion. Apple rejects apps that create accounts without it (5.1.1(v)); also GDPR Art. 17 and Israeli access/erasure rights. Backend is ready; iOS button is a backlog task.
- **High:** Privacy policy and terms are not published, and the operator is not named. Needed for the App Store and for any real user. HUMAN_TODO.
- **High:** Camera records video and sound of other people (guests, walkers, cleaners) with no notice to them or the owner. Draft notices written; iOS task open. Lawyer should review the sound-recording angle.
- **Medium:** Data regions are not pinned or documented (Railway, bucket, LiveKit); international transfers and DPAs unsigned.
- **Medium:** Events and daily summaries never expire (storage limitation).
- **Medium:** Apple sign-in token is not revoked at deletion (Apple requirement).
- **Medium:** Server logs contain invite tokens in URL paths and IP addresses.
- **Low:** No data export; no stated breach process; Israeli Amendment 13 database duties not assessed (lawyer).

**Checked, fine:** training-data sharing is opt-in and off by default; clips auto-delete; presigned links are short-lived; the camera shows when someone is watching or talking; no tracking, so no ATT prompt.

### 2026-11-11 (follow-up, "closing corners")

Fixed: events and daily summaries now expire after 365 days (`EVENT_RETENTION_DAYS`); request logs no longer contain invite tokens, query strings or IP addresses; owners can delete a household without deleting their account (`DELETE /household`). All with tests. Policy and `PRIVACY.md` updated to match.
Still open: in-app delete-account and notices (iOS), publishing the texts (owner details), regions and DPAs, Apple token revocation, data export. Medium risks "events never expire" and "logs contain tokens" are closed.

Also done: "Delete account" in the app (Household settings and the create-household screen), with confirmation, both languages, and `DogMonitorAPI.deleteAccount()` with tests. The High risk "no in-app account deletion" is closed once CI confirms the Swift builds (no Swift toolchain in this environment).
