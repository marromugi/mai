// Prints, as JSON, what scripts/deploy.sh and scripts/upload-fonts.sh need of one environment of
// wrangler.jsonc: the --env value that picks it, its Worker, its Turso database, its font bucket,
// and the secrets its Worker requires.
// Usage: node environment.mjs dev | prod
import { fileURLToPath } from "node:url";
import { unstable_readConfig } from "wrangler";

const environments = {
  prod: { wranglerEnv: "", database: "mai" },
  dev: { wranglerEnv: "dev", database: "mai-dev" },
};

const name = process.argv[2] ?? "";
if (!Object.hasOwn(environments, name)) {
  console.error("usage: environment.mjs dev | prod");
  process.exit(1);
}
const { wranglerEnv, database } = environments[name];
const config = unstable_readConfig({
  config: fileURLToPath(new URL("../wrangler.jsonc", import.meta.url)),
  env: wranglerEnv === "" ? undefined : wranglerEnv,
});
const fonts = config.r2_buckets.find((bucket) => bucket.binding === "FONTS");
if (fonts?.bucket_name === undefined) {
  console.error(`wrangler.jsonc gives ${name} no FONTS bucket`);
  process.exit(1);
}
console.log(
  JSON.stringify({
    wranglerEnv,
    worker: config.name,
    database,
    fontsBucket: fonts.bucket_name,
    secrets: config.secrets?.required ?? [],
  }),
);
