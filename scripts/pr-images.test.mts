// node --test scripts/pr-images.test.mts
//
// Runs pr-images.mts with a fake `gh` on PATH and a fetch stub loaded before it, and checks that the
// token is sent only to github.com and appears in no output, file name, or saved file.

import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import assert from "node:assert/strict";

const script = join(dirname(fileURLToPath(import.meta.url)), "pr-images.mts");
const token = "gho_FAKE0token0for0pr0images0test";
const png = Buffer.from("89504e470d0a1a0a", "hex");

const view = {
  body: "Before ![a](https://github.com/user-attachments/assets/one) and <img src=\"https://github.com/user-attachments/assets/two\">",
  comments: [
    { body: "no images here" },
    { body: "![leaky](https://github.com/user-attachments/assets/leaky)" },
    { body: "![elsewhere](https://images.example.com/three.png) http://github.com/plain.png" },
    { body: "![a [b] c](<https://images.example.com/four.png>)\n<img data-src=\"https://wrong.example.com/x\" src=https://images.example.com/five.png>" },
  ],
  reviews: [{ body: `![token in a name](https://github.com/user-attachments/assets/${token})` }],
};
const lineComments = ["see\nhttps://github.com/user-attachments/assets/six\n"];

// Every request is appended to requests.jsonl with the Authorization header it carried. `leaky`
// fails with the header in its message, as a library that echoes a request might.
const stub = `
import { appendFileSync } from "node:fs";
const log = process.env.STUB_LOG;
const png = Buffer.from("89504e470d0a1a0a", "hex");
globalThis.fetch = async (input, init = {}) => {
  const url = new URL(input);
  const authorization = init.headers?.Authorization ?? null;
  appendFileSync(log, JSON.stringify({ url: url.href, authorization }) + "\\n");
  if (url.pathname.endsWith("/leaky")) throw new Error("request failed: " + authorization);
  if (url.origin === "https://github.com") {
    const location = "https://objects.example.com/" + url.pathname.split("/").pop() + "?sig=x";
    // A fetch left to follow redirects itself is taken to keep its headers.
    if (init.redirect !== "manual") return globalThis.fetch(location, init);
    return new Response(null, { status: 302, headers: { location } });
  }
  return new Response(png, { status: 200, headers: { "content-type": "image/png" } });
};
`;

const fakeGh = `#!/bin/sh
if [ "$1 $2" = "auth token" ]; then echo "${token}"; exit 0; fi
if [ "$1 $2" = "pr view" ]; then cat "$GH_VIEW"; exit 0; fi
if [ "$1" = "api" ]; then cat "$GH_LINE_COMMENTS"; exit 0; fi
exit 1
`;

test("downloads every image and never shows the token", async (t) => {
  const work = await mkdtemp(join(tmpdir(), "pr-images-test-"));
  t.after(() => rm(work, { recursive: true, force: true }));
  const bin = join(work, "bin");
  const out = join(work, "out");
  await Promise.all([mkdir(bin), mkdir(out)]);
  await writeFile(join(bin, "gh"), fakeGh);
  await chmod(join(bin, "gh"), 0o755);
  await writeFile(join(work, "view.json"), JSON.stringify(view));
  await writeFile(join(work, "lines.txt"), lineComments.map((body) => JSON.stringify(body) + "\n").join(""));
  await writeFile(join(work, "stub.mjs"), stub);

  const result = await new Promise<{ code: number; stdout: string; stderr: string }>((resolve) => {
    execFile(
      process.execPath,
      ["--import", join(work, "stub.mjs"), script, "61"],
      {
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          TMPDIR: out,
          GH_VIEW: join(work, "view.json"),
          GH_LINE_COMMENTS: join(work, "lines.txt"),
          STUB_LOG: join(work, "requests.jsonl"),
        },
      },
      (error, stdout, stderr) =>
        resolve({ code: typeof error?.code === "number" ? error.code : 0, stdout, stderr }),
    );
  });

  assert.equal(result.code, 1, "one image fails, so the run fails");
  assert.ok(!result.stdout.includes(token), "token in stdout");
  assert.ok(!result.stderr.includes(token), "token in stderr");
  assert.match(result.stderr, /^comment 2 image 1: not downloaded, request failed: Bearer \[token\]$/m);

  const saved = result.stdout.trim().split("\n");
  assert.deepEqual(
    saved.map((line) => line.split(": ")[0]),
    [
      "body image 1",
      "body image 2",
      "comment 3 image 1",
      "comment 4 image 1",
      "comment 4 image 2",
      "review 1 image 1",
      "line comment 1 image 1",
    ],
  );

  const folders = await readdir(out);
  assert.equal(folders.length, 1);
  const names = [...folders, ...(await readdir(join(out, folders[0])))];
  assert.ok(names.every((name) => !name.includes(token)), `token in a file name: ${names}`);
  for (const line of saved) {
    const path = line.split(": ")[1];
    assert.ok(!path.includes(token), "token in a printed path");
    assert.deepEqual(await readFile(path), png);
  }

  const requests = (await readFile(join(work, "requests.jsonl"), "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as { url: string; authorization: string | null });
  for (const request of requests) {
    const toGitHub = new URL(request.url).origin === "https://github.com";
    assert.equal(request.authorization, toGitHub ? `Bearer ${token}` : null, request.url);
  }
  assert.ok(!requests.some((r) => r.url.startsWith("http://")), "a plain http URL was fetched");
  assert.ok(!requests.some((r) => r.url.includes("wrong.example.com")), "data-src was taken for src");
});
