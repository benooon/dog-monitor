import { createHash } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";

export type ByteRange = { start: number; end: number } | "unsatisfiable" | undefined;

/**
 * Parses a single `Range: bytes=…` header (Safari needs ranges to play video). Undefined means
 * "send the whole file" (no header, or a multi-range/unknown unit we choose not to support).
 */
export function parseRange(header: string | undefined, size: number): ByteRange {
  if (!header) return undefined;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return undefined;
  const [, a = "", b = ""] = m;
  if (a === "" && b === "") return undefined;
  let start: number;
  let end: number;
  if (a === "") {
    const suffix = Number(b);
    if (suffix === 0) return "unsatisfiable";
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(a);
    end = b === "" ? size - 1 : Math.min(Number(b), size - 1);
  }
  if (start >= size || start > end) return "unsatisfiable";
  return { start, end };
}

const etags = new WeakMap<Buffer, string>();

/** Sends an in-memory file with caching headers, ETag and byte-range support. */
export function serveBytes(request: FastifyRequest, reply: FastifyReply, bytes: Buffer, type: string, maxAge: number): FastifyReply {
  let etag = etags.get(bytes);
  if (!etag) {
    etag = `"${createHash("sha256").update(bytes).digest("base64url").slice(0, 22)}"`;
    etags.set(bytes, etag);
  }
  reply
    .header("content-type", type)
    .header("cache-control", `public, max-age=${maxAge}`)
    .header("etag", etag)
    .header("accept-ranges", "bytes")
    .header("x-content-type-options", "nosniff");
  if (request.headers["if-none-match"] === etag) return reply.code(304).send();

  const range = parseRange(request.headers.range, bytes.length);
  if (range === "unsatisfiable") {
    return reply.code(416).header("content-range", `bytes */${bytes.length}`).send();
  }
  if (range) {
    return reply
      .code(206)
      .header("content-range", `bytes ${range.start}-${range.end}/${bytes.length}`)
      .send(bytes.subarray(range.start, range.end + 1));
  }
  return reply.send(bytes);
}
