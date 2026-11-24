// Downloads the images in a pull request's body, comments, and reviews into a new temporary folder,
// and prints one line per image: where it was found and the path it was saved to.
//
//   node scripts/pr-images.mts <PR number>
//
// The GitHub token is read from `gh auth token` and only ever sent to https://github.com. Every line
// this writes goes through `say`, which blanks the token out.

import { execFile } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

type Source = { label: string; text: string };
type Image = { label: string; url: URL };

const extensions: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/svg+xml": "svg",
};

let token = "";

function say(stream: NodeJS.WriteStream, line: string): void {
  stream.write((token === "" ? line : line.replaceAll(token, "[token]")) + "\n");
}

function imageURLs(text: string): URL[] {
  const found: URL[] = [];
  const markdown = String.raw`!\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(?:<([^>]+)>|([^)\s]+))`;
  const img = String.raw`<img\b[^>]*?(?<![\w-])src\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))`;
  const bare = String.raw`^[ \t]*(https://github\.com/user-attachments/assets/\S+)[ \t]*$`;
  const pattern = new RegExp(`${markdown}|${img}|${bare}`, "gim");
  for (const match of text.matchAll(pattern)) {
    const raw = match.slice(1).find((group) => group !== undefined) ?? "";
    if (!URL.canParse(raw)) continue;
    const url = new URL(raw);
    if (url.protocol === "https:") found.push(url);
  }
  return found;
}

async function sources(pr: string): Promise<Source[]> {
  const { stdout } = await run("gh", ["pr", "view", pr, "--json", "body,comments,reviews"], {
    maxBuffer: 64 * 1024 * 1024,
  });
  const view = JSON.parse(stdout) as {
    body: string;
    comments: { body: string }[];
    reviews: { body: string }[];
  };
  const inline = await run(
    "gh",
    ["api", `repos/{owner}/{repo}/pulls/${pr}/comments`, "--paginate", "--jq", ".[].body | @json"],
    { maxBuffer: 64 * 1024 * 1024 },
  );
  const lineComments = inline.stdout
    .split("\n")
    .filter((line) => line !== "")
    .map((line) => JSON.parse(line) as string);
  return [
    { label: "body", text: view.body },
    ...view.comments.map((c, i) => ({ label: `comment ${i + 1}`, text: c.body })),
    ...view.reviews.map((r, i) => ({ label: `review ${i + 1}`, text: r.body })),
    ...lineComments.map((body, i) => ({ label: `line comment ${i + 1}`, text: body })),
  ];
}

async function download(url: URL): Promise<Response> {
  let current = url;
  for (let hop = 0; hop < 5; hop++) {
    const headers: Record<string, string> =
      current.origin === "https://github.com" ? { Authorization: `Bearer ${token}` } : {};
    const response = await fetch(current, { headers, redirect: "manual" });
    const location = response.headers.get("location");
    if (response.status >= 300 && response.status < 400 && location !== null) {
      current = new URL(location, current);
      continue;
    }
    return response;
  }
  throw new Error("too many redirects");
}

async function main(): Promise<number> {
  const pr = process.argv[2];
  if (pr === undefined || !/^\d+$/.test(pr)) {
    say(process.stderr, "usage: node scripts/pr-images.mts <PR number>");
    return 2;
  }
  token = (await run("gh", ["auth", "token"])).stdout.trim();

  const images: Image[] = [];
  for (const source of await sources(pr)) {
    imageURLs(source.text).forEach((url, i) =>
      images.push({ label: `${source.label} image ${i + 1}`, url }),
    );
  }
  if (images.length === 0) {
    say(process.stderr, `PR ${pr} has no images`);
    return 1;
  }

  const folder = await mkdtemp(join(tmpdir(), `pr-${pr}-images-`));
  let failed = 0;
  for (const [n, image] of images.entries()) {
    try {
      const response = await download(image.url);
      const type = (response.headers.get("content-type") ?? "").split(";")[0].trim();
      const extension = extensions[type];
      if (!response.ok || extension === undefined) {
        throw new Error(`answered ${response.status} ${type || "with no content type"}`);
      }
      const path = join(folder, `${String(n + 1).padStart(2, "0")}.${extension}`);
      await writeFile(path, Buffer.from(await response.arrayBuffer()));
      say(process.stdout, `${image.label}: ${path}`);
    } catch (error) {
      failed++;
      const reason = error instanceof Error ? error.message : String(error);
      say(process.stderr, `${image.label}: not downloaded, ${reason}`);
    }
  }
  return failed === 0 ? 0 : 1;
}

try {
  process.exitCode = await main();
} catch (error) {
  say(process.stderr, error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
