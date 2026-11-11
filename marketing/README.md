# Marketing

Daily Instagram reels for Dog Monitor, in Hebrew and English.

**The idea:** sell the dog, not the camera. Every reel is a tiny comedy about what a dog does while you're out (the sofa, the door, the sock, the trash), caught by the old iPhone on the shelf, with a real Dog Monitor moment in it (the alert, talking to the dog, the daily summary). Calm, warm, a bit deadpan. See `voice.md`.

## Folders

```
marketing/
  voice.md                      voice file for the ig-* skills
  reel-engine/                  renders reels: one HTML canvas scene per reel + render.js (pipes frames into ffmpeg)
    sofa.html                   reel 1, "He never gets on the sofa"
    sfx.py                      original sound effects (no licensed music)
  reels/YYYY-MM-DD-<slug>/      one folder per reel, ready to post
    reel-en.mp4, reel-he.mp4    1080x1920, 30 fps, 15 s, H.264 + AAC
    caption-en.txt, caption-he.txt
```

## Watch them

Open a reel's `.mp4` on GitHub (it plays in the browser), e.g. `reels/2026-11-11-sofa/reel-en.mp4`.

## Make a new reel

1. Write the idea with `/ig-reel` (hooks scored with `hookscore.py`, beats timed with `beats.py`) and the captions with `/ig-caption` + `/ig-human`. One idea per reel; the dog is the hero; one real app moment.
2. Copy `reel-engine/sofa.html` to `reel-engine/<slug>.html` and change the timeline (`dogState`, `draw`) and `COPY` (en + he). Reuse the room, dog and overlays; vary the room, the dog's coat and the gag so the feed doesn't repeat.
3. Check stills at the busiest moments: `REEL=<slug> node stills.js en 1 5 8 10 13.8` (and `he`), look at them.
4. Render: `python3 sfx.py sfx.wav` (adjust the cue times), then `REEL=<slug> node render.js en v-en.mp4` and `he`, mux the sound (`ffmpeg -i v-en.mp4 -i sfx.wav -map 0:v -map 1:a -c:v copy -c:a aac -shortest`), then make the committed copy smaller: `-c:v libx264 -crf 25 -preset slow -tune grain` (~6 MB). Keep reels ≤ 8 MB each so the repo stays light.
5. Commit to `reels/<date>-<slug>/` with both captions.

Setup: `cd marketing/reel-engine && npm ci` (fonts), plus ffmpeg and Playwright's Chromium.

## Rules

- Only claim what the app does today (see the voice file). If an ad needs a feature, add it to the backlog first.
- No stock "AI" imagery, no real people, no known characters or brands.
- Hebrew is written in Hebrew, not translated word for word; the dog is רקס in Hebrew reels.

## Posting

Until the Meta Graph API token exists (docs/HUMAN_TODO.md), the owner posts by hand from the reel folder. After that, `marketing/publish/` posts the day's reel automatically (backlog task).

## Reel log

| Date | Slug | Hook | Gag | App moment |
|---|---|---|---|---|
| 2026-11-11 | sofa | "He never gets on the sofa." | Dog sneaks onto the sofa a minute after you leave, gets caught, slides off | Sofa alert + talk from live view |
