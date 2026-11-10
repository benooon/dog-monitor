import type { FastifyInstance } from "fastify";

const startedAt = Date.now();

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get(
    "/health",
    {
      schema: {
        response: {
          200: {
            type: "object",
            properties: {
              status: { type: "string" },
              uptimeSeconds: { type: "number" },
              version: { type: "string" },
            },
            required: ["status", "uptimeSeconds", "version"],
          },
        },
      },
    },
    async () => ({
      status: "ok",
      uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
      version: process.env.npm_package_version ?? "0.1.0",
    }),
  );
}
