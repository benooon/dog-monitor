#!/usr/bin/env node
// Downloads the clips your household marked right or wrong, for training a Create ML model.
// See docs/TRAINING.md. Node 22+, no dependencies.
//
//   DOGMONITOR_API=https://<your-api-host> DOGMONITOR_TOKEN=<owner JWT> \
//     node scripts/export-training-data.mjs ./training-data
//
// Output: <dir>/<event type>/<correct|wrong>/<event id>.mp4 (+ .jpg snapshot) and <dir>/labels.csv.
// Re-running only downloads what is new (it resumes after the newest event in labels.csv).

import { createWriteStream, existsSync, mkdirSync, readFileSync, appendFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const api = process.env.DOGMONITOR_API?.replace(/\/$/, "");
const token = process.env.DOGMONITOR_TOKEN;
const outDir = process.argv[2] ?? "training-data";

if (!api || !token) {
  console.error("Set DOGMONITOR_API and DOGMONITOR_TOKEN (the household owner's token). See docs/TRAINING.md.");
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });
const csvPath = join(outDir, "labels.csv");
if (!existsSync(csvPath)) writeFileSync(csvPath, "eventId,cameraId,type,state,startedAt,feedback,clip,snapshot\n");

/** The newest startedAt already exported, so a re-run continues from there. */
function lastExported() {
  const lines = readFileSync(csvPath, "utf8").trim().split("\n").slice(1);
  return lines.length ? lines[lines.length - 1].split(",")[4] : undefined;
}

async function download(url, path) {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download failed (${res.status}): ${path}`);
  await pipeline(Readable.fromWeb(res.body), createWriteStream(path));
}

let after = lastExported();
let total = 0;
for (;;) {
  const url = new URL(`${api}/training/labeled`);
  if (after) url.searchParams.set("after", after);
  const res = await fetch(url, { headers: { authorization: `Bearer ${token}` } });
  if (res.status === 403) {
    console.error("Training data is off. Turn on “Help improve detection” in the app (Household), then label some events.");
    process.exit(1);
  }
  if (!res.ok) throw new Error(`GET /training/labeled failed: ${res.status} ${await res.text()}`);
  const { items, next } = await res.json();

  for (const item of items) {
    const dir = join(outDir, item.type, item.feedback);
    mkdirSync(dir, { recursive: true });
    const clip = join(dir, `${item.eventId}.mp4`);
    await download(item.clipUrl, clip);
    let snapshot = "";
    if (item.snapshotUrl) {
      snapshot = join(dir, `${item.eventId}.jpg`);
      await download(item.snapshotUrl, snapshot);
    }
    appendFileSync(
      csvPath,
      [item.eventId, item.cameraId ?? "", item.type, item.state ?? "", item.startedAt, item.feedback, clip, snapshot].join(",") + "\n",
    );
    total += 1;
  }
  if (!next) break;
  after = next;
}
console.log(`Exported ${total} new clip(s) to ${outDir}`);
