import { readFileSync } from "node:fs";
import { X509Certificate, createPrivateKey } from "node:crypto";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { CompactSign } from "jose";
import { createAppStoreVerifier, type TransactionVerifier } from "../src/billing/app-store.js";
import { cameraLimit, effectivePlan } from "../src/billing/plans.js";
import type { DbHandle } from "../src/db/client.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

const fixture = (name: string) => readFileSync(new URL(`./fixtures/app-store/${name}`, import.meta.url), "utf8");
const der = (pem: string) => new X509Certificate(pem).raw.toString("base64");

const root = fixture("root.pem");
const intermediate = fixture("intermediate.pem");
const leaf = fixture("leaf.pem");
const BUNDLE = "com.benooon.dogmonitor";
const MONTHLY = "com.benooon.dogmonitor.premium.monthly";
const NOW = new Date("2027-06-01T12:00:00Z");
const DAY = 24 * 60 * 60 * 1000;

const verifier = createAppStoreVerifier({
  bundleId: BUNDLE,
  productIds: [MONTHLY],
  rootFingerprints: [new X509Certificate(root).fingerprint256.toLowerCase()],
});

interface SignOptions {
  chain?: string[];
  key?: string;
  alg?: string;
}

/** A StoreKit-style signed transaction from the test chain. */
async function signTransaction(payload: Record<string, unknown>, options: SignOptions = {}): Promise<string> {
  const chain = options.chain ?? [leaf, intermediate, root];
  const key = createPrivateKey(fixture(options.key ?? "leaf.key"));
  return new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: options.alg ?? "ES256", x5c: chain.map(der) })
    .sign(key);
}

function transaction(overrides: Record<string, unknown> = {}) {
  return {
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000000",
    bundleId: BUNDLE,
    productId: MONTHLY,
    purchaseDate: NOW.getTime() - DAY,
    expiresDate: NOW.getTime() + 29 * DAY,
    type: "Auto-Renewable Subscription",
    environment: "Sandbox",
    ...overrides,
  };
}

async function expectRejected(promise: Promise<unknown>, code: string) {
  await expect(promise).rejects.toMatchObject({ code });
}

describe("App Store transaction verification", () => {
  it("accepts a transaction signed by the trusted chain", async () => {
    const result = await verifier.verify(await signTransaction(transaction({ appAccountToken: "ABC-DEF" })), NOW);
    expect(result).toMatchObject({
      originalTransactionId: "2000000000000000",
      productId: MONTHLY,
      environment: "Sandbox",
      revokedAt: null,
      appAccountToken: "abc-def",
    });
    expect(result.expiresAt.getTime()).toBe(NOW.getTime() + 29 * DAY);
  });

  it("rejects another root", async () => {
    const chain = [fixture("other-leaf.pem"), fixture("other-intermediate.pem"), fixture("other-root.pem")];
    await expectRejected(verifier.verify(await signTransaction(transaction(), { chain, key: "other-leaf.key" }), NOW), "untrusted_certificate");
  });

  it("rejects a leaf from another chain next to the trusted root", async () => {
    const chain = [fixture("other-leaf.pem"), intermediate, root];
    await expectRejected(verifier.verify(await signTransaction(transaction(), { chain, key: "other-leaf.key" }), NOW), "untrusted_certificate");
  });

  it("rejects a leaf without Apple's signing extension", async () => {
    const chain = [fixture("plain-leaf.pem"), intermediate, root];
    await expectRejected(verifier.verify(await signTransaction(transaction(), { chain, key: "plain-leaf.key" }), NOW), "untrusted_certificate");
  });

  it("rejects a signature that doesn't match the leaf", async () => {
    await expectRejected(verifier.verify(await signTransaction(transaction(), { key: "other-leaf.key" }), NOW), "invalid_signature");
  });

  it("rejects certificates outside their validity", async () => {
    await expectRejected(verifier.verify(await signTransaction(transaction()), new Date("2090-01-01T00:00:00Z")), "untrusted_certificate");
  });

  it("rejects malformed input, other apps and unknown products", async () => {
    await expectRejected(verifier.verify("not.a.jws", NOW), "invalid_transaction");
    await expectRejected(verifier.verify(await signTransaction(transaction(), { chain: [leaf, intermediate] }), NOW), "invalid_transaction");
    await expectRejected(verifier.verify(await signTransaction(transaction({ bundleId: "com.other.app" })), NOW), "wrong_bundle");
    await expectRejected(verifier.verify(await signTransaction(transaction({ productId: "coins" })), NOW), "unknown_product");
    await expectRejected(verifier.verify(await signTransaction(transaction({ expiresDate: undefined })), NOW), "invalid_transaction");
  });
});

describe("plans", () => {
  it("is premium only while paid up", () => {
    expect(effectivePlan({ planExpiresAt: null }, NOW)).toBe("free");
    expect(effectivePlan({ planExpiresAt: new Date(NOW.getTime() + 1) }, NOW)).toBe("premium");
    expect(effectivePlan({ planExpiresAt: NOW }, NOW)).toBe("free");
  });

  it("limits free cameras only when enforced", () => {
    expect(cameraLimit({ planExpiresAt: null }, NOW, true)).toBe(1);
    expect(cameraLimit({ planExpiresAt: new Date(NOW.getTime() + DAY) }, NOW, true)).toBe(4);
    expect(cameraLimit({ planExpiresAt: null }, NOW, false)).toBe(4);
  });
});

describe.skipIf(!hasDatabase)("subscription routes", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  let clock = NOW.getTime();

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h, { transactions: verifier as TransactionVerifier, enforcePlanLimits: true, now: () => clock });
    app = ctx.app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    clock = NOW.getTime();
    await truncateAll(h);
  });

  async function signIn(sub: string) {
    const res = await app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub }), nonce: TEST_NONCE, name: sub },
    });
    return { authorization: `Bearer ${res.json().token}` };
  }

  async function household(sub: string) {
    const auth = await signIn(sub);
    const res = await app.inject({ method: "POST", url: "/households", headers: auth, payload: { name: sub } });
    return { auth, householdId: res.json().id as string };
  }

  async function pairCamera(auth: Record<string, string>, name: string) {
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: auth })).json();
    return app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: name } });
  }

  async function purchase(auth: Record<string, string>, payload: Record<string, unknown>) {
    return app.inject({
      method: "POST",
      url: "/subscription/apple",
      headers: auth,
      payload: { signedTransaction: await signTransaction(payload) },
    });
  }

  it("starts free with one camera, and premium lifts the limit", async () => {
    const { auth, householdId } = await household("owner");
    expect((await app.inject({ method: "GET", url: "/subscription", headers: auth })).json()).toEqual({
      plan: "free",
      expiresAt: null,
      productId: null,
      limits: { cameras: 1 },
      usage: { cameras: 0 },
    });
    expect((await pairCamera(auth, "Living room")).statusCode).toBe(201);
    const blocked = await pairCamera(auth, "Door");
    expect(blocked.statusCode).toBe(409);
    expect(blocked.json()).toEqual({ error: "camera_limit_reached", limit: 1 });

    const res = await purchase(auth, transaction({ appAccountToken: householdId }));
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ plan: "premium", productId: MONTHLY, limits: { cameras: 4 }, usage: { cameras: 1 } });
    expect((await pairCamera(auth, "Door")).statusCode).toBe(201);
    expect((await app.inject({ method: "GET", url: "/household", headers: auth })).json().plan).toBe("premium");

    // Lapsed: back to free; paired cameras keep working, but no new ones.
    clock = NOW.getTime() + 30 * DAY;
    expect((await app.inject({ method: "GET", url: "/subscription", headers: auth })).json()).toMatchObject({
      plan: "free",
      limits: { cameras: 1 },
      usage: { cameras: 2 },
    });
  });

  it("never shortens premium with an older transaction and ends it on revocation", async () => {
    const { auth } = await household("owner");
    await purchase(auth, transaction({ transactionId: "2", expiresDate: NOW.getTime() + 60 * DAY }));
    const older = await purchase(auth, transaction({ transactionId: "1", expiresDate: NOW.getTime() + 5 * DAY }));
    expect(new Date(older.json().expiresAt).getTime()).toBe(NOW.getTime() + 60 * DAY);

    const revoked = await purchase(auth, transaction({ transactionId: "2", revocationDate: NOW.getTime() }));
    expect(revoked.json()).toMatchObject({ plan: "free", expiresAt: null });
  });

  it("lets one subscription unlock only one household", async () => {
    const first = await household("owner-1");
    const second = await household("owner-2");
    expect((await purchase(first.auth, transaction())).statusCode).toBe(200);
    const res = await purchase(second.auth, transaction());
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "subscription_in_use" });

    const tokenForFirst = await purchase(second.auth, transaction({ originalTransactionId: "3", appAccountToken: first.householdId }));
    expect(tokenForFirst.statusCode).toBe(409);
  });

  async function notify(notification: Record<string, unknown>, options: SignOptions = {}) {
    return app.inject({
      method: "POST",
      url: "/app-store/notifications",
      payload: { signedPayload: await signTransaction(notification, options) },
    });
  }

  async function subscription(auth: Record<string, string>) {
    return (await app.inject({ method: "GET", url: "/subscription", headers: auth })).json();
  }

  it("applies renewals and refunds from App Store server notifications", async () => {
    const { auth } = await household("owner");
    await purchase(auth, transaction());

    const renewal = await notify({
      notificationType: "DID_RENEW",
      notificationUUID: "n-1",
      data: { bundleId: BUNDLE, environment: "Sandbox", signedTransactionInfo: await signTransaction(transaction({ transactionId: "9", expiresDate: NOW.getTime() + 59 * DAY })) },
    });
    expect(renewal.statusCode).toBe(200);
    expect(new Date((await subscription(auth)).expiresAt).getTime()).toBe(NOW.getTime() + 59 * DAY);

    const refund = await notify({
      notificationType: "REFUND",
      data: { signedTransactionInfo: await signTransaction(transaction({ transactionId: "9", revocationDate: NOW.getTime() })) },
    });
    expect(refund.statusCode).toBe(200);
    expect((await subscription(auth)).plan).toBe("free");
  });

  it("finds a new subscriber by appAccountToken and ignores what isn't ours", async () => {
    const { auth, householdId } = await household("owner");
    const first = await notify({
      notificationType: "SUBSCRIBED",
      data: { signedTransactionInfo: await signTransaction(transaction({ originalTransactionId: "77", appAccountToken: householdId.toUpperCase() })) },
    });
    expect(first.statusCode).toBe(200);
    expect((await subscription(auth)).plan).toBe("premium");

    expect((await notify({ notificationType: "TEST" })).statusCode).toBe(200);
    const otherProduct = await notify({ data: { signedTransactionInfo: await signTransaction(transaction({ productId: "coins" })) } });
    expect(otherProduct.statusCode).toBe(200);
    const stranger = await notify({ data: { signedTransactionInfo: await signTransaction(transaction({ originalTransactionId: "88" })) } });
    expect(stranger.statusCode).toBe(200);
  });

  it("rejects notifications that aren't signed by the trusted chain", async () => {
    const forged = await notify({ notificationType: "DID_RENEW" }, { key: "other-leaf.key" });
    expect(forged.statusCode).toBe(400);
    const chain = [fixture("other-leaf.pem"), fixture("other-intermediate.pem"), fixture("other-root.pem")];
    const otherRoot = await notify({ notificationType: "DID_RENEW" }, { chain, key: "other-leaf.key" });
    expect(otherRoot.statusCode).toBe(400);
  });

  it("is for owners, and rejects bad transactions", async () => {
    const { auth } = await household("owner");
    const bad = await app.inject({
      method: "POST",
      url: "/subscription/apple",
      headers: auth,
      payload: { signedTransaction: await signTransaction(transaction(), { key: "other-leaf.key" }) },
    });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toEqual({ error: "invalid_signature" });

    const invite = (await app.inject({ method: "POST", url: "/invites", headers: auth })).json();
    const member = await signIn("member");
    await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, headers: member, payload: { as: "member" } });
    expect((await purchase(member, transaction())).statusCode).toBe(403);
    expect((await app.inject({ method: "GET", url: "/subscription", headers: member })).statusCode).toBe(200);
  });
});
