import { randomBytes } from "node:crypto";
import { createServer } from "node:net";
import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => {
        if (address === null || typeof address === "string") {
          reject(new Error("a TCP server listening on a port has an address with a port"));
        } else {
          resolve(address.port);
        }
      });
    });
  });
}

export default defineConfig(async () => {
  // `test/sqld.ts` starts the tests' libSQL server on this port.
  const port = await freePort();
  process.env["MAI_TEST_SQLD_PORT"] = String(port);
  return {
    test: { globalSetup: ["./test/sqld.ts"] },
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TURSO_URL: `http://127.0.0.1:${port}`,
            TURSO_TOKEN: "",
            CHALLENGE_KEY: randomBytes(32).toString("base64"),
            REFRESH_TOKEN_KEY: randomBytes(32).toString("base64"),
            APPLE_CLIENT_ID: "com.marromugi.mai",
            APPLE_TEAM_ID: "TESTTEAM00",
            APPLE_SIGN_IN_KEY_ID: "TESTKEY000",
            // Each test that signs in makes its own key (test/sign-in.test.ts).
            APPLE_SIGN_IN_KEY: "",
          },
        },
      }),
    ],
  };
});
