# Dog Monitor

Turn a spare iPhone into a smart dog camera. One or more phones act as **cameras** (left at home on a charger), and family members' phones act as **viewers**: live video, push notifications, an event timeline and a daily summary. Dog-state detection (barking, whining, resting, restless, at the door, forbidden zone) runs **on the camera device**, so only meaningful events trigger a push.

The full product and technical spec is in [`docs/SPEC.md`](docs/SPEC.md).

To train a bark model on your own labeled clips, see [`docs/TRAINING.md`](docs/TRAINING.md).

## Repository layout

| Path | What |
|---|---|
| `ios/project.yml` | XcodeGen definition of the iOS project (the `.xcodeproj` is generated, never committed) |
| `ios/App/` | SwiftUI app (camera mode + viewer mode), String Catalogs (English + Hebrew) |
| `ios/Tests/` | App unit tests |
| `ios/Packages/DogMonitorCore/` | Pure-Swift package (models, event engine, API client); builds and tests on Linux |
| `backend/` | Node 22 + TypeScript + Fastify API, PostgreSQL via Drizzle, deployed to Railway |
| `.github/workflows/ci.yml` | CI: core tests (Linux), iOS build + tests (macOS), backend lint + tests |
| `docs/` | Spec, backlog, decisions, progress log, owner to-dos |

## iOS app

Requirements: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd ios
xcodegen generate
open DogMonitor.xcodeproj
```

Core package tests run anywhere Swift 6 is installed: `cd ios/Packages/DogMonitorCore && swift test`.

## Backend

Requirements: Node 22 and PostgreSQL 15+.

```sh
cd backend
cp .env.example .env            # then edit DATABASE_URL etc.
npm ci
export $(grep -v '^#' .env | xargs)
npm run migrate                 # apply Drizzle migrations
npm run dev                     # http://localhost:3000/health
```

Other scripts: `npm run lint` (ESLint + `tsc --noEmit`), `npm test` (Vitest; database tests run when `DATABASE_URL` is set and **reset that database**, so point it at a throwaway one), `npm run build`, `npm run db:generate` (create a migration after editing `src/db/schema.ts`).

Deployment: Railway builds `backend/Dockerfile` (service root `backend`), runs migrations as a pre-deploy step and health-checks `/health` (see `backend/railway.json`). All configuration comes from environment variables listed in `backend/.env.example`.

## CI

Every push to `main` runs `.github/workflows/ci.yml`:

- **core**: `swift test` for DogMonitorCore in a `swift:6.1` Linux container.
- **ios**: `xcodegen generate` + `xcodebuild test` on a macOS runner, only when `ios/` or the workflows changed since the last iOS run (macOS minutes are expensive); otherwise the previous result is carried over.
- **backend**: `npm ci && npm run lint && npm test` against a Postgres 16 service.

Results and logs are published to the `ci-results` branch (`STATUS.md`, `*.log`), so tools without GitHub API access can read them:

```sh
git fetch origin ci-results:refs/remotes/origin/ci-results
git show origin/ci-results:STATUS.md
```

## How the agent loop works

This project is built mostly by autonomous coding agents following [`CLAUDE.md`](CLAUDE.md). Each session they pull `main`, fix CI if it is red, take the first open task from [`docs/BACKLOG.md`](docs/BACKLOG.md), claim it, implement it with tests, push straight to `main`, and log their work in [`docs/PROGRESS.md`](docs/PROGRESS.md). Decisions go in [`docs/DECISIONS.md`](docs/DECISIONS.md). Anything only the owner can do (accounts, secrets, payments) goes in [`docs/HUMAN_TODO.md`](docs/HUMAN_TODO.md).
