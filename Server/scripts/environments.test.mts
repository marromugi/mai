// Checks whose App Store purchases each deployed environment of wrangler.jsonc takes.
import assert from "node:assert/strict";
import { it } from "node:test";
import { fileURLToPath } from "node:url";
import { unstable_readConfig } from "wrangler";

const config = fileURLToPath(new URL("../wrangler.jsonc", import.meta.url));

await it("production takes Production and Sandbox, as App Review buys with Sandbox", () => {
  assert.equal(
    unstable_readConfig({ config }).vars["APP_STORE_ENVIRONMENTS"],
    "Production,Sandbox",
  );
});

await it("staging takes Sandbox only", () => {
  assert.equal(
    unstable_readConfig({ config, env: "staging" }).vars["APP_STORE_ENVIRONMENTS"],
    "Sandbox",
  );
});
