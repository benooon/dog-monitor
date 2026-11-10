import type { FastifyInstance } from "fastify";

/** Path prefix of invite links: `https://<api host>/invite/<token>` opens the app (Universal Link). */
export const INVITE_LINK_PATH = "/invite/";

/**
 * `GET /.well-known/apple-app-site-association`: lets iOS open invite links in the app.
 * Answers 404 until the Apple team id is configured (`appIds` empty).
 */
export async function appLinkRoutes(app: FastifyInstance, opts: { appIds: string[] }): Promise<void> {
  app.get("/.well-known/apple-app-site-association", async (_request, reply) => {
    if (opts.appIds.length === 0) return reply.code(404).send({ error: "app_links_not_configured" });
    return reply.header("content-type", "application/json").send({
      applinks: {
        details: [{ appIDs: opts.appIds, components: [{ "/": `${INVITE_LINK_PATH}*`, comment: "Household invites" }] }],
      },
    });
  });

  // Opened in a browser (app not installed, or link pasted on a computer).
  app.get<{ Params: { token: string } }>(`${INVITE_LINK_PATH}:token`, async (_request, reply) => {
    return reply
      .header("content-type", "text/html; charset=utf-8")
      .send(
        "<!doctype html><meta name=viewport content='width=device-width'><title>Dog Monitor</title>" +
          "<p style='font:17px -apple-system,sans-serif;margin:2em'>Open this link on your iPhone with Dog Monitor installed, " +
          "or type the 6-digit code in the app.</p>",
      );
  });
}
