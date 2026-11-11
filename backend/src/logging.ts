/**
 * Request log hygiene: our logs must not contain invite tokens (in `/invite/<token>`),
 * query strings, or client IP addresses and ports (GDPR data minimisation).
 */
export function redactUrl(url: string): string {
  const path = url.split("?")[0] ?? "";
  return path.replace(/^(\/invite\/)[^/]+/, "$1:token");
}

export type LoggedRequest = { method: string; url: string };

/** Fastify `serializers.req`: only the method and the redacted path. */
export function serializeRequest(request: { method?: string; url?: string }): LoggedRequest {
  return { method: request.method ?? "", url: redactUrl(request.url ?? "") };
}
