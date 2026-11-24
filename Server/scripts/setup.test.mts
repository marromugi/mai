// Runs scripts/setup.sh against stand-ins for wrangler, turso and curl, in a copy of Server/ whose
// fonts.json lists two made-up fonts, and checks what each run makes or changes.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
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
const fonts = ["A.ttf", "B.ttf"];

// Each stand-in logs its call to $LOG. What it answers comes from the variables setUp passes.
const wrangler = `#!/bin/bash
echo "wrangler $*" >>"$LOG"
case "$1 $2" in
  "secret list")
    case "$LISTED" in
      missing) echo "✘ [ERROR] Worker \\"$WORKER\\" not found." >&2; exit 1 ;;
      "logged out") echo "✘ [ERROR] Not logged in." >&2; exit 1 ;;
      *) echo "$LISTED" ;;
    esac
    ;;
  "secret bulk") cp "$3" "$LOG.secrets" ;;
  "r2 bucket")
    if [[ "$3" == list ]]; then
      echo "Listing buckets..."
      for bucket in $BUCKETS; do printf 'name:           %s\\ncreation_date:  2026-11-01T00:00:00.000Z\\n\\n' "$bucket"; done
    fi
    ;;
  "r2 object")
    if [[ "$3" == get ]]; then
      name="\${4##*/}"
      file=""
      shift 4
      while [[ $# -gt 0 ]]; do [[ "$1" == --file ]] && file="$2"; shift; done
      if [[ " $STORED " == *" $name "* ]]; then printf 'font:%s' "$name" >"$file"
      elif [[ " $STALE " == *" $name "* ]]; then printf 'old' >"$file"
      else echo "✘ [ERROR] The specified key does not exist." >&2; exit 1
      fi
    fi
    ;;
esac
exit 0
`;
const turso = `#!/bin/bash
case "$1 $2" in
  "db list")
    echo "turso $*" >>"$LOG"
    echo "NAME     URL"
    for database in $DATABASES; do echo "$database     libsql://$database-me.turso.io"; done
    ;;
  "db shell")
    if [[ $# -eq 4 ]]; then
      echo "turso $1 $2 $3 (count)" >>"$LOG"
      printf 'COUNT(*)  \\n%s  \\n' "$OBJECTS"
    else
      echo "turso $* <$(wc -c | tr -d ' ') bytes" >>"$LOG"
    fi
    ;;
  "db show") echo "turso $*" >>"$LOG"; echo "libsql://$3-me.turso.io" ;;
  "db tokens") echo "turso $*" >>"$LOG"; echo "token-for-$4" ;;
  *) echo "turso $*" >>"$LOG" ;;
esac
`;
const curl = `#!/bin/bash
echo "curl $*" >>"$LOG"
printf 'font:%s' "\${4##*/}" >"$3"
`;

/** Calls that make or change something, with what follows --file left out. */
const changing =
  /^(turso db create|turso db shell \S+ <|wrangler r2 bucket create|wrangler r2 object put|wrangler secret (bulk|put)|wrangler deploy)/;

let directory = "";
let copy = "";

function executable(path: string, text: string) {
  writeFileSync(path, text);
  chmodSync(path, 0o755);
}

/** The secrets file setup.sh gave wrangler: a JSON object of strings. */
function secretsIn(text: string): Record<string, string> {
  const parsed: unknown = JSON.parse(text);
  assert.ok(typeof parsed === "object" && parsed !== null && !Array.isArray(parsed));
  const secrets: Record<string, string> = {};
  for (const [name, value] of Object.entries(parsed)) {
    assert.equal(typeof value, "string", `${name} is a string`);
    secrets[name] = String(value);
  }
  return secrets;
}

const listing = (names: string[]) =>
  JSON.stringify(names.map((name) => ({ name, type: "secret_text" })));

type State = {
  listed: string;
  databases: string;
  objects: string;
  buckets: string;
  stored?: string;
  stale?: string;
  variables?: Record<string, string>;
};

/** Everything production has. */
const production: State = {
  listed: listing(required),
  databases: "other mai",
  objects: "27",
  buckets: "mai-photos mai-fonts other",
  stored: fonts.join(" "),
};

/** Nothing staging needs exists. */
const nothing: State = {
  listed: "missing",
  databases: "mai",
  objects: "0",
  buckets: "mai-photos mai-fonts",
};

function setUp(environment: string, state: State) {
  const log = join(directory, `log.${randomUUID()}`);
  const env: Record<string, string | undefined> = {
    ...process.env,
    PATH: `${join(directory, "bin")}:${process.env["PATH"]}`,
    LOG: log,
    LISTED: state.listed,
    WORKER: environment === "staging" ? "mai-server-staging" : "mai-server",
    DATABASES: state.databases,
    OBJECTS: state.objects,
    BUCKETS: state.buckets,
    STORED: state.stored ?? "",
    STALE: state.stale ?? "",
  };
  for (const name of ["APPLE_TEAM_ID", "APPLE_SIGN_IN_KEY_ID", "APPLE_SIGN_IN_KEY_FILE"]) {
    delete env[name];
  }
  Object.assign(env, state.variables);
  const run = spawnSync(join(copy, "scripts", "setup.sh"), [environment], {
    cwd: directory,
    env,
    encoding: "utf8",
  });
  const calls = existsSync(log)
    ? readFileSync(log, "utf8")
        .split("\n")
        .filter((line) => line !== "")
    : [];
  const sent = existsSync(`${log}.secrets`)
    ? secretsIn(readFileSync(`${log}.secrets`, "utf8"))
    : undefined;
  return {
    status: run.status,
    stderr: run.stderr,
    calls,
    changes: calls
      .filter((call) => changing.test(call))
      .map((call) => call.replace(/ --file \S+/, "").replace(/^(wrangler secret bulk) \S+/, "$1")),
    sent,
  };
}

/** The shell variables the Apple secrets are made from. */
const apple = () => ({
  APPLE_TEAM_ID: "TEAM",
  APPLE_SIGN_IN_KEY_ID: "KEY",
  APPLE_SIGN_IN_KEY_FILE: join(directory, "key.p8"),
});

const schemaLoad = (database: string) =>
  `turso db shell ${database} <${readFileSync(join(server, "schema.sql")).length} bytes`;

await describe("setup.sh", async () => {
  before(() => {
    directory = mkdtempSync(
      join(existsSync("/private/tmp") ? "/private/tmp" : tmpdir(), "mai-setup-test."),
    );
    copy = join(directory, "Server");
    mkdirSync(join(copy, "node_modules", ".bin"), { recursive: true });
    mkdirSync(join(directory, "bin"));
    for (const name of ["scripts", "src", "wrangler.jsonc", "package.json", "schema.sql"]) {
      cpSync(join(server, name), join(copy, name), { recursive: true });
    }
    writeFileSync(
      join(copy, "fonts.json"),
      JSON.stringify({
        source: "https://fonts.test/commit",
        files: fonts.map((name) => ({
          name,
          path: `ofl/x/${name}`,
          sha256: createHash("sha256").update(`font:${name}`).digest("hex"),
        })),
      }),
    );
    symlinkSync(join(server, "node_modules", "wrangler"), join(copy, "node_modules", "wrangler"));
    executable(join(copy, "node_modules", ".bin", "wrangler"), wrangler);
    executable(join(directory, "bin", "turso"), turso);
    executable(join(directory, "bin", "curl"), curl);
    writeFileSync(
      join(directory, "key.p8"),
      "-----BEGIN PRIVATE KEY-----\r\nAAAA\r\nBBBB\r\n-----END PRIVATE KEY-----\r\n",
    );
    writeFileSync(join(directory, "empty.p8"), "");
  });

  after(() => rmSync(directory, { recursive: true, force: true }));

  await it("changes nothing in an environment that has everything", () => {
    const run = setUp("prod", production);
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(run.changes, []);
  });

  await it("makes everything for an environment that has nothing, and deploys no code", () => {
    const run = setUp("staging", { ...nothing, variables: apple() });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(run.changes, [
      "turso db create mai-staging",
      schemaLoad("mai-staging"),
      "wrangler r2 bucket create mai-photos-staging --update-config=false",
      "wrangler r2 bucket create mai-fonts-staging --update-config=false",
      "wrangler r2 object put mai-fonts-staging/fonts/A.ttf --content-type font/ttf --remote",
      "wrangler r2 object put mai-fonts-staging/fonts/B.ttf --content-type font/ttf --remote",
      "wrangler secret bulk --env staging",
    ]);
    assert.deepEqual(run.sent, {
      TURSO_URL: "libsql://mai-staging-me.turso.io",
      TURSO_TOKEN: "token-for-mai-staging",
      CHALLENGE_KEY: run.sent?.["CHALLENGE_KEY"],
      REFRESH_TOKEN_KEY: run.sent?.["REFRESH_TOKEN_KEY"],
      APPLE_CLIENT_ID: "com.marromugi.mai",
      APPLE_TEAM_ID: "TEAM",
      APPLE_SIGN_IN_KEY_ID: "KEY",
      APPLE_SIGN_IN_KEY: "AAAABBBB",
    });
    assert.equal(Buffer.from(run.sent?.["CHALLENGE_KEY"] ?? "", "base64").length, 32);
    assert.equal(Buffer.from(run.sent?.["REFRESH_TOKEN_KEY"] ?? "", "base64").length, 32);
    assert.notEqual(run.sent?.["CHALLENGE_KEY"], run.sent?.["REFRESH_TOKEN_KEY"]);
  });

  await it("loads the schema into a database that exists but holds nothing", () => {
    const run = setUp("prod", { ...production, objects: "0" });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(run.changes, [schemaLoad("mai")]);
  });

  await it("sends only the secrets the Worker lacks", () => {
    const run = setUp("prod", {
      ...production,
      listed: listing(
        required.filter((name) => name !== "TURSO_TOKEN" && name !== "CHALLENGE_KEY"),
      ),
    });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(run.changes, ["wrangler secret bulk --env "]);
    assert.deepEqual(Object.keys(run.sent ?? {}).toSorted(), ["CHALLENGE_KEY", "TURSO_TOKEN"]);
    assert.equal(run.sent?.["TURSO_TOKEN"], "token-for-mai");
  });

  await it("puts only the fonts missing or different from fonts.json", () => {
    const both = setUp("prod", { ...production, stored: "", stale: "A.ttf" });
    assert.equal(both.status, 0, both.stderr);
    assert.deepEqual(both.changes, [
      "wrangler r2 object put mai-fonts/fonts/A.ttf --content-type font/ttf --remote",
      "wrangler r2 object put mai-fonts/fonts/B.ttf --content-type font/ttf --remote",
    ]);
    const one = setUp("prod", { ...production, stored: "B.ttf" });
    assert.deepEqual(one.changes, [
      "wrangler r2 object put mai-fonts/fonts/A.ttf --content-type font/ttf --remote",
    ]);
  });

  await it("makes nothing when the shell lacks what a missing secret is made from", () => {
    const run = setUp("staging", nothing);
    assert.equal(run.status, 1);
    assert.match(run.stderr, /APPLE_TEAM_ID APPLE_SIGN_IN_KEY_ID APPLE_SIGN_IN_KEY_FILE/);
    assert.deepEqual(run.calls, ["wrangler secret list --env staging"]);
  });

  await it("takes a key file holding no key as missing", () => {
    const run = setUp("staging", {
      ...nothing,
      variables: { ...apple(), APPLE_SIGN_IN_KEY_FILE: join(directory, "empty.p8") },
    });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /APPLE_SIGN_IN_KEY_FILE/);
    assert.deepEqual(run.calls, ["wrangler secret list --env staging"]);
  });

  await it("stops at an answer from wrangler other than a Worker not found", () => {
    const run = setUp("staging", { ...nothing, listed: "logged out", variables: apple() });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /Not logged in/);
    assert.deepEqual(run.calls, ["wrangler secret list --env staging"]);
  });

  await it("stops before the buckets when the database's count isn't a number", () => {
    const run = setUp("prod", { ...production, objects: "Error: unauthorized" });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /not a number/);
    assert.deepEqual(run.changes, []);
    assert.ok(!run.calls.some((call) => call.startsWith("wrangler r2")));
  });

  await it("takes no environment but staging and prod", () => {
    const run = setUp("dev", production);
    assert.equal(run.status, 1);
    assert.deepEqual(run.calls, []);
  });
});
