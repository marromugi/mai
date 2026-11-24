// Runs scripts/deploy.sh against stand-ins for wrangler and turso, in a copy of Server/ under
// /private/tmp, and checks which secrets each deploy sends.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const server = fileURLToPath(new URL("..", import.meta.url));
const required = [
  "TURSO_URL",
  "TURSO_TOKEN",
  "CHALLENGE_KEY",
  "REFRESH_TOKEN_KEY",
  "APPLE_CLIENT_ID",
  "APPLE_TEAM_ID",
  "APPLE_SIGN_IN_KEY_ID",
  "APPLE_SIGN_IN_KEY",
];

let directory = "";
let copy = "";

// `secret list` answers $LISTED, or, when it is "missing" or "logged out", fails as wrangler does.
// `deploy` keeps the file it is given with --secrets-file at $LOG.secrets.
const wrangler = `#!/bin/bash
echo "wrangler $*" >>"$LOG"
if [[ "$1 $2" == "secret list" ]]; then
  case "$LISTED" in
    missing) echo "✘ [ERROR] Worker \\"$WORKER\\" not found." >&2; exit 1 ;;
    "logged out") echo "✘ [ERROR] Not logged in." >&2; exit 1 ;;
    *) echo "$LISTED" ;;
  esac
elif [[ "$1" == deploy ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --secrets-file ]]; then cp "$2" "$LOG.secrets"; fi
    shift
  done
fi
exit 0
`;
const turso = `#!/bin/bash
echo "turso $*" >>"$LOG"
echo "turso:$*"
`;

before(() => {
  directory = mkdtempSync(
    join(existsSync("/private/tmp") ? "/private/tmp" : tmpdir(), "mai-deploy-test."),
  );
  copy = join(directory, "Server");
  mkdirSync(join(copy, "node_modules", ".bin"), { recursive: true });
  mkdirSync(join(directory, "bin"));
  for (const name of ["scripts", "src", "wrangler.jsonc", "package.json"]) {
    cpSync(join(server, name), join(copy, name), { recursive: true });
  }
  symlinkSync(join(server, "node_modules", "wrangler"), join(copy, "node_modules", "wrangler"));
  writeFileSync(join(copy, "node_modules", ".bin", "wrangler"), wrangler);
  chmodSync(join(copy, "node_modules", ".bin", "wrangler"), 0o755);
  writeFileSync(join(directory, "bin", "turso"), turso);
  chmodSync(join(directory, "bin", "turso"), 0o755);
  writeFileSync(
    join(directory, "key.p8"),
    "-----BEGIN PRIVATE KEY-----\nAAAA\nBBBB\n-----END PRIVATE KEY-----\n",
  );
});

after(() => rmSync(directory, { recursive: true, force: true }));

const apple = () => ({
  APPLE_TEAM_ID: "TEAM",
  APPLE_SIGN_IN_KEY_ID: "KEY",
  APPLE_SIGN_IN_KEY_FILE: join(directory, "key.p8"),
});

function deploy(environment: string, listed: string, variables: Record<string, string> = {}) {
  const log = join(directory, `log.${crypto.randomUUID()}`);
  const env: Record<string, string | undefined> = {
    ...process.env,
    PATH: `${join(directory, "bin")}:${process.env["PATH"]}`,
    LOG: log,
    LISTED: listed,
    WORKER: environment === "dev" ? "mai-server-dev" : "mai-server",
    ...variables,
  };
  for (const name of ["APPLE_TEAM_ID", "APPLE_SIGN_IN_KEY_ID", "APPLE_SIGN_IN_KEY_FILE"]) {
    if (!(name in variables)) delete env[name];
  }
  const run = spawnSync(join(copy, "scripts", "deploy.sh"), [environment], {
    cwd: directory,
    env,
    encoding: "utf8",
  });
  const calls = existsSync(log)
    ? readFileSync(log, "utf8")
        .split("\n")
        .filter((line) => line !== "")
    : [];
  const sent: Record<string, string> | undefined = existsSync(`${log}.secrets`)
    ? JSON.parse(readFileSync(`${log}.secrets`, "utf8"))
    : undefined;
  return { status: run.status, stderr: run.stderr, calls, sent };
}

const listing = (names: string[]) =>
  JSON.stringify(names.map((name) => ({ name, type: "secret_text" })));

describe("deploy.sh", () => {
  it("deploys a Worker that has every secret without sending or making any", () => {
    const run = deploy("prod", listing(required));
    assert.equal(run.status, 0);
    assert.deepEqual(run.calls, ["wrangler secret list --env ", "wrangler deploy --env "]);
    assert.equal(run.sent, undefined);
  });

  it("sends only the secrets the Worker lacks", () => {
    const run = deploy(
      "dev",
      listing(required.filter((name) => name !== "TURSO_TOKEN" && name !== "CHALLENGE_KEY")),
    );
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(Object.keys(run.sent ?? {}).toSorted(), ["CHALLENGE_KEY", "TURSO_TOKEN"]);
    assert.equal(run.sent?.["TURSO_TOKEN"], "turso:db tokens create mai-dev");
    assert.equal(Buffer.from(run.sent?.["CHALLENGE_KEY"] ?? "", "base64").length, 32);
    assert.match(run.calls.at(-1) ?? "", /^wrangler deploy --env dev --secrets-file /);
  });

  it("makes every secret for a Worker not deployed yet", () => {
    const run = deploy("dev", "missing", apple());
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(run.sent, {
      TURSO_URL: "turso:db show mai-dev --url",
      TURSO_TOKEN: "turso:db tokens create mai-dev",
      CHALLENGE_KEY: run.sent?.["CHALLENGE_KEY"],
      REFRESH_TOKEN_KEY: run.sent?.["REFRESH_TOKEN_KEY"],
      APPLE_CLIENT_ID: "com.marromugi.mai",
      APPLE_TEAM_ID: "TEAM",
      APPLE_SIGN_IN_KEY_ID: "KEY",
      APPLE_SIGN_IN_KEY: "AAAABBBB",
    });
    assert.notEqual(run.sent?.["CHALLENGE_KEY"], run.sent?.["REFRESH_TOKEN_KEY"]);
  });

  it("names the shell variables it needs and deploys nothing without them", () => {
    const run = deploy("prod", "missing");
    assert.equal(run.status, 1);
    assert.match(run.stderr, /APPLE_TEAM_ID APPLE_SIGN_IN_KEY_ID APPLE_SIGN_IN_KEY_FILE/);
    assert.deepEqual(run.calls, ["wrangler secret list --env "]);
  });

  it("stops at an answer from wrangler other than a Worker not found", () => {
    const run = deploy("dev", "logged out", apple());
    assert.equal(run.status, 1);
    assert.match(run.stderr, /Not logged in/);
    assert.deepEqual(run.calls, ["wrangler secret list --env dev"]);
  });

  it("takes no environment but dev and prod", () => {
    const run = deploy("staging", listing(required));
    assert.equal(run.status, 1);
    assert.deepEqual(run.calls, []);
  });
});
