import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { invites } from "../src/db/schema.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

const codes = vi.hoisted(() => ({ next: [] as string[] }));
vi.mock("../src/pairing/secrets.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/pairing/secrets.js")>();
  return { ...actual, newInviteCode: () => codes.next.shift() ?? actual.newInviteCode() };
});

// Security audit 2026-11, run 2: a 6-digit code must never point at two households.
describe.skipIf(!hasDatabase)("invite code uniqueness", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h);
  });
  afterAll(async () => {
    await ctx.app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
    codes.next = [];
  });

  async function owner(sub: string) {
    const res = await ctx.app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub }), nonce: TEST_NONCE, name: sub },
    });
    const auth = { authorization: `Bearer ${res.json().token}` };
    const household = (await ctx.app.inject({ method: "POST", url: "/households", headers: auth, payload: { name: sub } })).json();
    return { auth, householdId: household.id as string };
  }

  const createInvite = (auth: Record<string, string>) => ctx.app.inject({ method: "POST", url: "/invites", headers: auth });

  it("skips a code another unused invite holds, even when both are created at once", async () => {
    const a = await owner("a");
    const b = await owner("b");
    codes.next = ["111111", "111111", "222222", "333333"];
    const [ra, rb] = await Promise.all([createInvite(a.auth), createInvite(b.auth)]);
    expect(ra.statusCode).toBe(201);
    expect(rb.statusCode).toBe(201);
    expect(ra.json().code).not.toBe(rb.json().code);
    expect(await h.db.select().from(invites).where(eq(invites.code, "111111"))).toHaveLength(1);
  });

  it("reuses a code held only by an expired invite", async () => {
    const a = await owner("a");
    const b = await owner("b");
    await h.db.insert(invites).values({ token: "t".repeat(32), code: "444444", householdId: a.householdId, expiresAt: new Date(Date.now() - 1000) });
    codes.next = ["444444"];
    const res = await createInvite(b.auth);
    expect(res.json().code).toBe("444444");
    const rows = await h.db.select().from(invites).where(eq(invites.code, "444444"));
    expect(rows).toHaveLength(1);
    expect(rows[0]!.householdId).toBe(b.householdId);
  });
});
