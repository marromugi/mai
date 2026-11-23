import { problem } from "./http";

/** A font file's name as `fonts.json` lists them: no path, a font's extension, and short of R2's limit on a key. */
const fontName = /^\/fonts\/([A-Za-z0-9-]{1,100}\.(?:ttf|otf))$/;

/**
 * Answers `GET /fonts/<file>` from `bucket`, under `fonts/<file>`. Needs no session: the files are
 * the fonts' own, under their open licenses, and the request says only which file is wanted.
 * A file's contents never change under its name, so it is cached for good.
 */
export async function serveFont(request: Request, bucket: R2Bucket): Promise<Response> {
  if (request.method !== "GET") {
    const response = problem(405, "fonts are only fetched with GET");
    response.headers.set("Allow", "GET");
    return response;
  }
  const name = fontName.exec(new URL(request.url).pathname)?.[1];
  const object = name === undefined ? null : await bucket.get(`fonts/${name}`);
  if (object === null) {
    return problem(404, "there is no such font file");
  }
  const headers = new Headers({
    "Content-Type": "font/ttf",
    "Cache-Control": "public, max-age=31536000, immutable",
    ETag: object.httpEtag,
  });
  if (name?.endsWith(".otf") === true) headers.set("Content-Type", "font/otf");
  return new Response(object.body, { headers });
}
