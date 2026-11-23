import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        // SHA-256 of "test-token", the token the tests send.
        bindings: {
          ACCESS_TOKEN_SHA256: "4c5dc9b7708905f77f5e5d16316b5dfb425e68cb326dcd55a860e90a7707031e",
        },
      },
    }),
  ],
});
