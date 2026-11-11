import type { WaitlistLocale } from "../waitlist/email.js";

/**
 * Landing page copy (`/join`, `/he/join`). Voice: calm, warm, brief (CLAUDE.md). Only claims
 * what the app does today (marketing/voice.md): no encryption or region claims yet.
 */
export interface LandingCopy {
  title: string;
  description: string;
  h1: string;
  lede: string;
  videoLabel: string;
  emailLabel: string;
  emailPlaceholder: string;
  button: string;
  note: string;
  success: string;
  errEmail: string;
  errBusy: string;
  errNetwork: string;
  b1Title: string;
  b1: string;
  b2Title: string;
  b2: string;
  b3Title: string;
  b3: string;
  footer: string;
  otherLang: string;
}

export const LANDING_COPY: Record<WaitlistLocale, LandingCopy> = {
  en: {
    title: "Dog Monitor: what does Rex do when you're out?",
    description: "Your old iPhone becomes a camera that tells you what your dog is up to while you're out. Coming soon to iPhone.",
    h1: "What does Rex do when you're out?",
    lede: "Dog Monitor turns the old iPhone in your drawer into a camera that tells you what your dog is up to. Coming soon to iPhone.",
    videoLabel: "An illustrated dog sneaks onto the sofa, naps, and slides off when he's caught.",
    emailLabel: "Email",
    emailPlaceholder: "you@example.com",
    button: "Join the list",
    note: "We'll write once, when it's ready.",
    success: "You're on the list. We'll write when Dog Monitor is ready.",
    errEmail: "That email doesn't look right. Check it and try again.",
    errBusy: "Too many tries from here. Try again in a few minutes.",
    errNetwork: "Couldn't reach us. Check your connection and try again.",
    b1Title: "Your old iPhone is the camera",
    b1: "No new gadget. Put the phone from your drawer on a shelf, plug it in, and pair it with yours.",
    b2Title: "Know when he's on the sofa",
    b2: "A quiet alert when Rex gets on the sofa, waits at the door or keeps barking. Watch live and talk to him.",
    b3Title: "Private by design",
    b3: "Only people you invite to your household can watch. Saved clips are deleted automatically.",
    footer: "Dog Monitor for iPhone. Coming soon.",
    otherLang: "עברית",
  },
  he: {
    title: "Dog Monitor: מה רקס עושה כשאתם לא בבית?",
    description: "האייפון הישן שלכם הופך למצלמה שמספרת לכם מה הכלב עושה כשאתם לא בבית. בקרוב לאייפון.",
    h1: "מה רקס עושה כשאתם לא בבית?",
    lede: "Dog Monitor הופך את האייפון הישן מהמגירה למצלמה שמספרת לכם מה הכלב עושה. בקרוב לאייפון.",
    videoLabel: "כלב מאויר מתגנב לספה, נרדם, ומחליק ממנה כשתופסים אותו.",
    emailLabel: "אימייל",
    emailPlaceholder: "you@example.com",
    button: "הצטרפו לרשימה",
    note: "נכתוב פעם אחת, כשזה יהיה מוכן.",
    success: "אתם ברשימה. נכתוב כש-Dog Monitor יהיה מוכן.",
    errEmail: "נראה שהאימייל לא תקין. בדקו ונסו שוב.",
    errBusy: "יותר מדי ניסיונות מכאן. נסו שוב בעוד כמה דקות.",
    errNetwork: "לא הצלחנו להתחבר. בדקו את החיבור ונסו שוב.",
    b1Title: "האייפון הישן הוא המצלמה",
    b1: "בלי גאדג׳ט חדש. שימו את הטלפון מהמגירה על מדף, חברו לחשמל וצמדו אותו לטלפון שלכם.",
    b2Title: "תדעו כשהוא על הספה",
    b2: "התראה שקטה כשרקס עולה על הספה, מחכה ליד הדלת או לא מפסיק לנבוח. צפייה חיה, ואפשר גם לדבר איתו.",
    b3Title: "פרטי מההתחלה",
    b3: "רק מי שהזמנתם למשק הבית יכול לצפות. סרטונים שנשמרו נמחקים אוטומטית.",
    footer: "Dog Monitor לאייפון. בקרוב.",
    otherLang: "English",
  },
};
