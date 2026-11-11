# Dog Monitor voice (for the `ig-*` skills)

Use this file wherever an `ig-*` skill says `~/.claude/instagram/voice.md`.

## Who we are

- **Name:** Dog Monitor
- **Handle:** (owner to fill in once the Instagram account exists)
- **What we do, in one sentence:** Your old iPhone becomes a camera that tells you what your dog is up to while you're out.
- **Who we are talking to:** Dog owners in Israel and the US who leave the dog alone for a workday and wonder what happens. Mostly 25–45, one dog, apartment, a spare iPhone in a drawer.
- **What we sell:** An iPhone app. Free with one camera; Premium keeps a month of moments, a daily highlight reel and insights.

## What we sound like

- **On screen:** warm, dry, a little deadpan. The dog is the hero and the joke; the owner is the lovable fool who believes "he never gets on the sofa".
- **Words we use:** camera (the phone at home), watch live, pair, invite, household, your dog's name.
- **Words we never say:** stream, SFU, token, AI-powered, revolutionary, game-changer, smart home, surveillance, spy, nanny cam.
- **Swearing:** no. **Exclamation marks:** no. **Emoji in captions:** none, or one at most.
- **Face on camera:** faceless. Illustrated dog + real app screens. Later: real customer dog clips (with permission).
- **Voiceover:** none. On-screen text carries it, so it works muted. Sound effects only; trending audio may be added when posting.

## Our positions

1. Your dog has a secret life between 08:03 and 17:30, and it's funny.
2. You don't need to buy a camera. The best one is already in your drawer.
3. A dog camera should be calm: tell you what matters, not buzz all day.
4. Your living room shouldn't go to a server nobody can name. (Only claim features that have shipped: see docs/DECISIONS.md.)

## Off limits

- No fake reviews, fake user counts or invented customers.
- No "end-to-end encrypted" until the owner has checked encrypted live view on real phones (HUMAN_TODO; the code shipped 2026-11-11). Then say "live view is end-to-end encrypted", never "everything is encrypted": clips are not. No server-region claims until docs/PRIVACY.md exists.
- No shaming owners for leaving their dog alone; no anxiety bait ("Is your dog suffering?").
- No real people, no known characters, no other brands' mascots.

## Proof we can use

- The app sends an alert when the dog gets on the sofa, waits at the door, barks or whines (sofa needs the zone marked on the camera).
- You can talk to your dog from the live view.
- Free plan: one camera. Premium: up to 4 cameras.
- Everything else: `{{number}}` until it is real.

## The ask

- **Before launch:** "Join the list, link in bio" → the waitlist page (`/join`).
- **After launch:** "Download, link in bio" → App Store.
