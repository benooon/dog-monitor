import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fp from "fastify-plugin";
import type { JwtService, UserClaims } from "./jwt.js";

declare module "fastify" {
  interface FastifyRequest {
    /** Set by `app.authenticate` for signed-in users. */
    user?: UserClaims;
  }
  interface FastifyInstance {
    /** preHandler that requires `Authorization: Bearer <our JWT>`. */
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<FastifyReply | undefined>;
  }
}

export const authPlugin = fp(
  async (app: FastifyInstance, opts: { jwt: JwtService }) => {
    app.decorateRequest("user", undefined);
    app.decorate("authenticate", async (request: FastifyRequest, reply: FastifyReply) => {
      const header = request.headers.authorization;
      const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : undefined;
      const claims = token ? await opts.jwt.verify(token) : null;
      if (!claims) {
        // Returning the reply stops the hook chain (Fastify async hook contract).
        return reply.code(401).send({ error: "unauthorized" });
      }
      request.user = claims;
      return undefined;
    });
  },
  { name: "auth" },
);
