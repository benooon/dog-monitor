import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    globalSetup: ["test/global-setup.ts"],
    // DB tests share one database; run files one at a time.
    fileParallelism: false,
  },
});
