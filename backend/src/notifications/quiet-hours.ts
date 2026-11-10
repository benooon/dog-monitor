/** "HH:MM" or "HH:MM:SS" (Postgres `time`) → minutes after midnight, or null if malformed. */
export function parseTimeOfDay(value: string | null | undefined): number | null {
  if (!value) return null;
  const match = /^(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$/.exec(value);
  if (!match) return null;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  return hours < 24 && minutes < 60 ? hours * 60 + minutes : null;
}

/** Minutes after local midnight in `timeZone` (IANA), or null for an unknown zone. */
export function localMinutes(now: Date, timeZone: string): number | null {
  try {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(now);
    const hour = Number(parts.find((p) => p.type === "hour")?.value);
    const minute = Number(parts.find((p) => p.type === "minute")?.value);
    return Number.isFinite(hour) && Number.isFinite(minute) ? hour * 60 + minute : null;
  } catch {
    return null;
  }
}

export function isValidTimeZone(timeZone: string): boolean {
  return localMinutes(new Date(0), timeZone) !== null;
}

/**
 * Whether `now` falls in the quiet window [start, end) in the phone's time zone. Windows may wrap
 * midnight (22:00–07:00). Without a time zone or a complete window, nothing is quiet.
 */
export function inQuietHours(
  now: Date,
  timeZone: string | null | undefined,
  quietStart: string | null | undefined,
  quietEnd: string | null | undefined,
): boolean {
  const start = parseTimeOfDay(quietStart);
  const end = parseTimeOfDay(quietEnd);
  if (!timeZone || start === null || end === null || start === end) return false;
  const minutes = localMinutes(now, timeZone);
  if (minutes === null) return false;
  return start < end ? minutes >= start && minutes < end : minutes >= start || minutes < end;
}
