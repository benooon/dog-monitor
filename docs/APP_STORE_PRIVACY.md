# App Store privacy label (draft)

For App Store Connect → App Privacy. Based on `docs/PRIVACY.md` (2026-11-11). "Linked to you" = tied to the account. **Tracking: No** (no ads, no data brokers, no cross-app tracking, no ATT prompt needed). Re-check before each release.

| Apple category | Data | Collected | Linked | Purpose |
|---|---|---|---|---|
| Contact Info → Name | Name shared by Sign in with Apple (optional) | Yes | Yes | App functionality |
| Identifiers → User ID | Apple user id, device id | Yes | Yes | App functionality |
| Identifiers → Device ID | Push token (APNs) | Yes | Yes | App functionality |
| User Content → Photos or Videos | Event snapshots, clips, dog photo | Yes | Yes | App functionality (and Product Personalization: no) |
| User Content → Audio Data | Sound in clips, live talk-back (live is not stored) | Yes | Yes | App functionality |
| User Content → Other User Content | Dog name, traits, alert preferences | Yes | Yes | App functionality |
| Usage Data → Product Interaction | Right/wrong feedback on events (kept only if the owner opts in to training) | Yes | Yes | App functionality, Product Personalization |
| Purchases → Purchase History | Plan, product id, expiry | Yes | Yes | App functionality |
| Diagnostics → Performance Data | Battery, charging, thermal state of camera phone | Yes | Yes | App functionality |
| Other Data | Server logs with IP address (via the hosting provider) | Yes | Not linked by us | App functionality, security |

Not collected: location, contacts, health, financial info, browsing history, search history, advertising data, crash data (no crash SDK).

Also needed in App Store Connect: privacy policy URL (`/privacy`, from `docs/legal/privacy-policy.*`), support URL, account-deletion path (Settings → Account, ios task open), subscription terms in the app and the listing (price, period, auto-renewal, links to Terms and Privacy), age rating (camera/user-generated video: no public sharing).
