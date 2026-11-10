# הוראות לבעל חשבון המפתחים (Account Holder) – Dog Monitor

שלום, אנחנו מעלים אפליקציית iOS בשם Dog Monitor. יש כמה דברים שרק בעל החשבון יכול לעשות. זה לוקח בערך 20 דקות.

## 1. לאשר את ההסכם המעודכן (חובה, חוסם הכול)

1. נכנסים ל-https://developer.apple.com/account עם החשבון של בעל החשבון.
2. אם מופיע בראש הדף באנר על Program License Agreement, לוחצים עליו, קוראים ומאשרים (Agree).
3. נכנסים ל-https://appstoreconnect.apple.com ובודקים שהאזהרה הצהובה "Agreement Updated" נעלמה.

## 2. לרשום מזהים (Identifiers)

ב-developer.apple.com/account נכנסים ל-**Certificates, Identifiers & Profiles**.

**א. App Group.** נכנסים ל-Identifiers, לוחצים על `+`, בוחרים App Groups ויוצרים:
- `group.com.benooon.dogmonitor`

**ב. שלושה App IDs.** לוחצים על `+`, בוחרים App IDs, ואז App, ויוצרים (Explicit Bundle ID):

| תיאור | Bundle ID |
|---|---|
| Dog Monitor | `com.benooon.dogmonitor` |
| Dog Monitor Notification Service | `com.benooon.dogmonitor.NotificationService` |
| Dog Monitor Widgets | `com.benooon.dogmonitor.Widgets` |

בכל אחד מהשלושה מפעילים **App Groups** ובוחרים את `group.com.benooon.dogmonitor` (לוחצים Configure). בנוסף, באפליקציה הראשית (`com.benooon.dogmonitor`) מפעילים **Push Notifications**.

## 3. ליצור את האפליקציה ב-App Store Connect

ב-appstoreconnect.apple.com נכנסים ל-Apps, לוחצים על `+`, ואז New App:
- Platforms: iOS
- Name: Dog Monitor (אם תפוס, שם דומה)
- Primary Language: English
- Bundle ID: `com.benooon.dogmonitor`
- SKU: `dogmonitor`
- User Access: Full Access

## 4. מפתח להתראות (APNs)

ב-Certificates, Identifiers & Profiles נכנסים ל-**Keys**, לוחצים על `+`:
- Key Name: `Dog Monitor APNs`
- מסמנים **Apple Push Notifications service (APNs)**
- Continue, Register, ואז **Download**. אפשר להוריד את הקובץ רק פעם אחת, ולכן שומרים אותו.

שולחים לנו:
- קובץ `.p8`
- **Key ID** (10 תווים)
- **Team ID** (מופיע ב-developer.apple.com/account תחת Membership details)

## 5. מפתח ל-App Store Connect API (להעלאה אוטומטית ל-TestFlight)

ב-App Store Connect נכנסים ל-**Users and Access**, ואז **Integrations**, ואז **App Store Connect API**, ולוחצים על `+`:
- Name: `Dog Monitor CI`
- Access: **App Manager**
- Generate, ואז **Download API Key**. אפשר להוריד פעם אחת בלבד.

שולחים לנו:
- קובץ `AuthKey_XXXX.p8`
- **Key ID**
- **Issuer ID** (מופיע בראש אותו דף)

## 6. איך לשלוח את הסודות

קבצי `.p8` הם סודות. לא שולחים אותם במייל או בצ'אט פתוח, ולא מעלים ל-GitHub. שולחים דרך מנהל סיסמאות (1Password וכדומה) או מעבירים ל-Ben ישירות.

## רשימת בדיקה

- [ ] ההסכם אושר
- [ ] App Group נוצר
- [ ] שלושת ה-App IDs נוצרו עם היכולות הנכונות
- [ ] האפליקציה נוצרה ב-App Store Connect
- [ ] נשלחו: APNs `.p8` + Key ID + Team ID
- [ ] נשלחו: API `.p8` + Key ID + Issuer ID
