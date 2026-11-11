import http2 from "node:http2";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { exportPKCS8, exportSPKI, generateKeyPair, importSPKI, jwtVerify } from "jose";
import { ApnsClient, isDeadToken, type ApnsConfig } from "../src/notifications/apns.js";
import { buildEventPayload } from "../src/notifications/payload.js";

async function testConfig(): Promise<{ config: ApnsConfig; publicKey: string }> {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  return {
    config: {
      keyId: "KEY123",
      teamId: "TEAM456",
      privateKey: await exportPKCS8(privateKey),
      topic: "com.benooon.dogmonitor",
      environment: "sandbox",
    },
    publicKey: await exportSPKI(publicKey),
  };
}

interface Received {
  headers: http2.IncomingHttpHeaders;
  body: string;
}

/** A local cleartext HTTP/2 server standing in for APNs. */
async function fakeApns(respond: (r: Received) => { status: number; body?: string }) {
  const received: Received[] = [];
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    let body = "";
    stream.setEncoding("utf8");
    stream.on("data", (chunk: string) => (body += chunk));
    stream.on("end", () => {
      const r = { headers, body };
      received.push(r);
      const out = respond(r);
      stream.respond({ ":status": out.status });
      stream.end(out.body ?? "");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return { origin: `http://127.0.0.1:${port}`, received, close: () => new Promise<void>((r) => server.close(() => r())) };
}

describe("ApnsClient", () => {
  const cleanups: (() => Promise<void> | void)[] = [];
  afterEach(async () => {
    for (const c of cleanups.splice(0)) await c();
  });

  it("posts the payload with APNs headers and an ES256 provider token", async () => {
    const { config, publicKey } = await testConfig();
    const server = await fakeApns(() => ({ status: 200 }));
    const client = new ApnsClient(config, server.origin);
    cleanups.push(() => client.close(), server.close);

    const result = await client.send({ deviceToken: "abcd", payload: { aps: { alert: "hi" } }, collapseId: "e1", priority: 5 });
    expect(result).toEqual({ status: 200, reason: undefined });

    const [req] = server.received;
    expect(req!.headers[":path"]).toBe("/3/device/abcd");
    expect(req!.headers["apns-topic"]).toBe("com.benooon.dogmonitor");
    expect(req!.headers["apns-push-type"]).toBe("alert");
    expect(req!.headers["apns-priority"]).toBe("5");
    expect(req!.headers["apns-collapse-id"]).toBe("e1");
    expect(JSON.parse(req!.body)).toEqual({ aps: { alert: "hi" } });

    const token = String(req!.headers.authorization).replace(/^bearer /, "");
    const { payload, protectedHeader } = await jwtVerify(token, await importSPKI(publicKey, "ES256"));
    expect(protectedHeader).toMatchObject({ alg: "ES256", kid: "KEY123" });
    expect(payload.iss).toBe("TEAM456");
  });

  it("sends Live Activity updates to the liveactivity topic", async () => {
    const { config } = await testConfig();
    const server = await fakeApns(() => ({ status: 200 }));
    const client = new ApnsClient(config, server.origin);
    cleanups.push(() => client.close(), server.close);

    await client.send({ deviceToken: "abcd", payload: { aps: { event: "update" } }, pushType: "liveactivity", priority: 10 });
    const [req] = server.received;
    expect(req!.headers["apns-topic"]).toBe("com.benooon.dogmonitor.push-type.liveactivity");
    expect(req!.headers["apns-push-type"]).toBe("liveactivity");
  });

  it("reports Apple's error reason", async () => {
    const { config } = await testConfig();
    const server = await fakeApns(() => ({ status: 410, body: JSON.stringify({ reason: "Unregistered" }) }));
    const client = new ApnsClient(config, server.origin);
    cleanups.push(() => client.close(), server.close);
    const result = await client.send({ deviceToken: "dead", payload: {} });
    expect(result).toEqual({ status: 410, reason: "Unregistered" });
    expect(isDeadToken(result)).toBe(true);
    expect(isDeadToken({ status: 400, reason: "BadDeviceToken" })).toBe(true);
    expect(isDeadToken({ status: 429, reason: "TooManyRequests" })).toBe(false);
  });

  it("reuses the provider token for 50 minutes", async () => {
    const { config } = await testConfig();
    let now = 1_000_000_000_000;
    const client = new ApnsClient(config, "http://127.0.0.1:1", () => now);
    const first = await client.providerToken();
    now += 49 * 60 * 1000;
    expect(await client.providerToken()).toBe(first);
    now += 2 * 60 * 1000;
    expect(await client.providerToken()).not.toBe(first);
  });
});

describe("buildEventPayload", () => {
  const base = { eventId: "e1", cameraId: "c1", cameraName: "Living room" };

  it("builds a time-sensitive barking alert with the dog's name", () => {
    expect(
      buildEventPayload({ ...base, type: "prolongedBarking", dogName: "Rex", snapshotKey: "snap.jpg", snapshotUrl: "https://s3/snap" }),
    ).toEqual({
      aps: {
        alert: { title: "Living room", "loc-key": "%@ has been barking", "loc-args": ["Rex"] },
        sound: "default",
        "thread-id": "c1",
        category: "DOG_EVENT",
        "interruption-level": "time-sensitive",
        "mutable-content": 1,
      },
      eventId: "e1",
      cameraId: "c1",
      type: "prolongedBarking",
      snapshotKey: "snap.jpg",
      snapshotUrl: "https://s3/snap",
    });
  });

  it("falls back to generic copy without a dog name and stays silent when passive", () => {
    const payload = buildEventPayload({ ...base, type: "calmedDown", dogName: " " }) as { aps: Record<string, unknown> };
    expect(payload.aps.alert).toEqual({ title: "Living room", "loc-key": "Your dog has calmed down" });
    expect(payload.aps.sound).toBeUndefined();
    expect(payload.aps["interruption-level"]).toBe("passive");
    expect(payload.aps["mutable-content"]).toBeUndefined();
  });

  it("says sofa when the place is the sofa, and off-limits otherwise", () => {
    const alert = (input: Partial<Parameters<typeof buildEventPayload>[0]>) =>
      (buildEventPayload({ ...base, type: "forbiddenZone", ...input }) as { aps: { alert: unknown } }).aps.alert;
    expect(alert({ dogName: "Rex", place: "sofa" })).toEqual({ title: "Living room", "loc-key": "%@ is on the sofa", "loc-args": ["Rex"] });
    expect(alert({ place: "sofa" })).toEqual({ title: "Living room", "loc-key": "Your dog is on the sofa" });
    expect(alert({ dogName: "Rex", place: "offLimits" })).toEqual({
      title: "Living room",
      "loc-key": "%@ is somewhere off-limits",
      "loc-args": ["Rex"],
    });
    expect(alert({})).toEqual({ title: "Living room", "loc-key": "Your dog is somewhere off-limits" });
    // place only matters for forbiddenZone
    expect(
      (buildEventPayload({ ...base, type: "atDoor", place: "sofa" }) as { aps: { alert: { "loc-key": string } } }).aps.alert["loc-key"],
    ).toBe("Your dog is waiting at the door");
  });

  it("formats escalations in minutes", () => {
    const withDog = buildEventPayload({ ...base, type: "prolongedBarking", dogName: "Rex", escalationSeconds: 300 }) as {
      aps: { alert: unknown };
    };
    expect(withDog.aps.alert).toEqual({ title: "Living room", "loc-key": "%1$@ has been barking for %2$@ min", "loc-args": ["Rex", "5"] });
    const noDog = buildEventPayload({ ...base, type: "whining", escalationSeconds: 900 }) as { aps: { alert: unknown } };
    expect(noDog.aps.alert).toEqual({ title: "Living room", "loc-key": "Your dog has been whining for %@ min", "loc-args": ["15"] });
  });
});
