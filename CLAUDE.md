# Dog Monitor — instructions for autonomous agents

You are one of a team of autonomous coding agents building **Dog Monitor**, a native iOS app that turns a spare iPhone into a smart dog camera (live view for several family members, on-device bark and dog-state detection, push notifications). The full product spec is in `docs/SPEC.md`. Read it before your first task.

## Autonomy rules (the owner has granted full autonomy)

- **No approvals needed for anything inside this repo.** Make decisions yourself, commit, and **push directly to `main`**. Do not open PRs and do not wait for review.
- Never stop to ask questions. If something is ambiguous, pick the most reasonable option, write the decision in `docs/DECISIONS.md` (one line: date, decision, why), and continue.
- If a task is blocked by something only the human can do (Apple Developer account, secrets, paid services), add it to `docs/HUMAN_TODO.md`, mark the task `[blocked]` in `docs/BACKLOG.md`, and move on to the next task. Never fake credentials and never stub out a blocked feature in a way that pretends it works.
- Stay inside this repository. Do not create other repos, delete branches you did not create, or rewrite `main` history (no force push).

## The work loop (every session)

1. `git pull --rebase origin main`.
2. **Check CI first.** `git fetch origin ci-results:refs/remotes/origin/ci-results && git show origin/ci-results:STATUS.md` (the explicit refspec is needed in shallow clones). If the last run on `main` is red, your task is to fix it (logs are in the same branch, e.g. `git show origin/ci-results:ios-build.log | tail -200`). A green `main` comes before new features.
3. Open `docs/BACKLOG.md`, take the **first unchecked, unblocked** task, and change its line to `- [~] ... (in progress <date>)`. Commit and push this claim right away, so parallel agents skip it. If the push is rejected, pull, and if someone else claimed it, pick the next task.
4. Implement it in small, compiling steps. Add or update tests.
5. Run what can run locally (see "Verification"). Commit with clear messages and push to `main`. Rebase on conflicts; never discard other agents' work.
6. Mark the task `- [x]` in BACKLOG.md, and add any follow-up tasks you discovered at the right place in the list. Push.
7. If time remains, repeat from step 1. Before ending, append 1–3 lines to `docs/PROGRESS.md` (date, what you did, what's next).

## Repository layout

```
CLAUDE.md                this file
docs/SPEC.md             product + technical spec (source of truth)
docs/BACKLOG.md          ordered task list — the agents' queue
docs/DECISIONS.md        decisions log
docs/PROGRESS.md         session log
docs/HUMAN_TODO.md       things only the owner can do
ios/project.yml          XcodeGen project definition (the .xcodeproj is generated, never committed)
ios/App/                 SwiftUI app target (camera mode + viewer mode)
ios/NotificationService/ Notification Service Extension (rich push with snapshot)
ios/Packages/DogMonitorCore/  pure-Swift package: event engine, models, API client — platform-independent, unit-tested
backend/                 Node.js + TypeScript API server, deployed to Railway
.github/workflows/       CI (iOS build + tests on macOS, core tests, backend tests, TestFlight)
```

## Technical rules

- **iOS:** Swift 6, SwiftUI, iOS 17 minimum, Swift Concurrency (no Combine in new code). Use AVFoundation, Vision, SoundAnalysis, Core ML, UserNotifications. Live video goes through the LiveKit Swift SDK (via SPM).
- **Never hand-edit or commit `.xcodeproj`.** All targets, files, packages and settings go in `ios/project.yml` (XcodeGen). New source files inside the existing source folders are picked up automatically.
- **`DogMonitorCore` must build and test on Linux** (CI runs `swift test` in a `swift:6.1` container): Foundation only, no Apple-only frameworks (no UIKit/AVFoundation/Vision there). Put platform code in the app target.
- **Keep logic out of the UI.** Anything that can be pure Swift (event state machine, debouncing, thresholds, models, API client, summaries) lives in `DogMonitorCore` with unit tests, not in views or camera code.
- **Backend:** Node 22, TypeScript, Fastify, PostgreSQL (Railway plugin), Drizzle ORM, Vitest. APNs via token auth (.p8). LiveKit server SDK to mint room tokens. Clip storage: S3-compatible (Cloudflare R2 or Railway bucket) behind an interface.
- All configuration and secrets come from environment variables, documented in `backend/.env.example`. Never commit secrets.
- No new third-party dependency unless it clearly saves a lot of work. Record each one in DECISIONS.md.
- UI strings: English and Hebrew (String Catalog). The layout must work in RTL.

## Design and UI quality (Apple-level bar)

The app must look and feel like a first-party Apple app. Vendored skills in `.claude/skills/` encode the rules; read the relevant `SKILL.md` before touching UI:

- **Every SwiftUI change:** `swiftui-pro` (modern API, data flow, HIG) and `swiftui-design-principles` (spacing grid, type, restraint).
- **New components/screens:** `swiftui-ui-patterns`. **Glass surfaces and floating controls:** `swiftui-liquid-glass`.
- **Accessibility (not optional):** `ios-accessibility` — VoiceOver labels, Dynamic Type to AX5, Reduce Motion, 44pt targets.
- **Any user-facing text:** `writing-for-interfaces`, with the voice below.

House rules:

- Use the tokens in `ios/App/Design/` (`DS.Spacing`, `DS.Radius`, `DS.Motion`) and its components (`GlassCard`, `.glassSurface()`, `PrimaryButton`, `StatusPill`). No magic numbers, no hard-coded colors; system semantic colors and the asset-catalog accent only.
- Native first: `NavigationStack`, `List`/`Form` where they fit, `ContentUnavailableView` for empty/error states, `Label`, SF Symbols with `symbolEffect`, `sensoryFeedback` for haptics, `contentTransition(.numericText())` for changing numbers.
- Liquid Glass on iOS 26+ for floating chrome (camera overlay, live view controls, primary actions), always gated with `#if compiler(>=6.2)` + `#available(iOS 26, *)` and a material fallback — the deployment target stays iOS 17.
- Every screen has an RTL (Hebrew) and a dark-mode `#Preview`.

### Voice

Dog Monitor is **calm, warm and brief** — a friend watching your dog, not an alarm system. Short sentences, plain words, no exclamation marks, no jargon ("stream", "SFU", "token" never reach the UI). Errors say what happened and what to do next. Name the dog when we know it. Word list: *camera* (the phone at home), *watch live* (not "stream"), *pair* (connect a camera), *invite* (add family), *household* (not "home"/"family" in settings).

## Verification

- This Linux sandbox usually has **no Swift toolchain and no Xcode**. Swift code is verified by CI on a macOS runner, so write it carefully, keep each commit small, and check CI results on your next loop.
- Backend: `cd backend && npm ci && npm run lint && npm test` must pass locally before you push.
- CI publishes every run's status and logs to the `ci-results` branch (`STATUS.md`, `ios-build.log`, `core-test.log`, `backend-test.log`). That is how you learn whether your Swift compiled.
- CI also renders the main screens (iPhone + iPad; light, dark, Hebrew) to `ci-results/screenshots/` (`git archive origin/ci-results screenshots | tar -x`, then look at the JPEGs). After a UI change, look at your screens there and fix what looks off. New screens: add them to `ios/Tests/ScreenshotTests.swift`.
- A task touching Swift is only done once CI on `main` is green for it. If your push turned CI red, fixing it is your next task.

## Style

- Small focused files, clear names, comments only where intent is not obvious.
- Commit messages: imperative, prefixed with the area: `ios:`, `core:`, `backend:`, `ci:`, `docs:`.
