import { parseBase, parseEnvelope, parseWritingId } from "./envelope";

export { Writings } from "./writings";

/**
 * The server keeps only sealed writings, and knows of each only its ID, updated time and size.
 * Routes are listed in `Server/README.md`.
 */
export default {
  async fetch(request, env): Promise<Response> {
    const expected = parseDigest(env.ACCESS_TOKEN_SHA256);
    if (expected === undefined) {
      return problem(500, "the server has no ACCESS_TOKEN_SHA256 secret of 64 hex digits");
    }
    if (!(await isAllowed(request, expected))) {
      return problem(401, "the Authorization header doesn't hold this server's token");
    }

    const path = new URL(request.url).pathname.split("/").slice(1);
    if (path[0] !== "writings" || path.length > 2) {
      return problem(404, "the only routes are /writings and /writings/<ID>");
    }
    const writings = env.WRITINGS.getByName("owner");

    if (path.length === 1) {
      if (request.method !== "GET") {
        return problem(405, "/writings is only read, with GET");
      }
      return Response.json({ writings: await writings.list() });
    }

    const id = parseWritingId(path[1] ?? "");
    if (id === undefined) {
      return problem(404, "a writing's ID is a UUID");
    }
    switch (request.method) {
      case "GET": {
        const read = await writings.read(id);
        if (read === undefined) {
          return problem(404, "the server has no writing with this ID");
        }
        return new Response(read.bytes, {
          headers: { "Content-Type": "application/octet-stream", "Mai-Revision": read.revision },
        });
      }
      case "PUT": {
        if (request.headers.get("Content-Type") !== "application/octet-stream") {
          return problem(415, "a sealed writing is sent as application/octet-stream");
        }
        const base = parseBase(request.headers.get("Mai-Base-Revision"));
        if (!base.ok) {
          return problem(400, base.reason);
        }
        const envelope = await parseEnvelope(await request.arrayBuffer());
        if (!envelope.ok) {
          return problem(400, envelope.reason);
        }
        if (envelope.value.id !== id) {
          return problem(400, "the sealed writing's ID is not the one in the path");
        }
        const saved = await writings.save(envelope.value, base.value);
        return Response.json({ revision: saved.revision }, { status: saved.saved ? 200 : 409 });
      }
      default:
        return problem(405, "a writing is read with GET and saved with PUT");
    }
  },
} satisfies ExportedHandler<Env>;

function problem(status: number, reason: string): Response {
  return Response.json({ error: reason }, { status });
}

function parseDigest(hex: string | undefined): Uint8Array | undefined {
  if (hex === undefined || !/^[0-9a-f]{64}$/i.test(hex)) {
    return undefined;
  }
  return Uint8Array.from(hex.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
}

async function isAllowed(request: Request, expected: Uint8Array): Promise<boolean> {
  const header = request.headers.get("Authorization");
  if (header === null || !header.startsWith("Bearer ")) {
    return false;
  }
  const token = new TextEncoder().encode(header.slice("Bearer ".length));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", token));
  return crypto.subtle.timingSafeEqual(digest, expected);
}
