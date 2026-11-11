/** MVP limits from SPEC §3. */
export const LIMITS = {
  camerasPerHousehold: 4,
  viewersPerCamera: 5,
  usersPerHousehold: 6,
  /** Each dog can hold a 512 KiB photo in Postgres, so the count is capped (audit 2026-11, run 2). */
  dogsPerHousehold: 10,
} as const;
