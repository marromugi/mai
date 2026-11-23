import { parseBase, parseEnvelope, parseWritingId } from "./envelope";
import { callerOf } from "./sessions";
import { Store, type Answer, type Refusal } from "./store";

/**
 * The server keeps only sealed writings, and knows of each only its ID, updated time and size.
 * Routes are listed in `Server/README.md`.
 */
export default {
  async fetch(request, env): Promise<Response> {
    const caller = await callerOf(request.headers.get("Authorization"));
    if (caller === undefined) {
      return problem(401, "the Authorization header doesn't hold a session token");
    }

    const store = Store.open(env.TURSO_URL, env.TURSO_TOKEN);
    const now = Date.now();
    /** A request turned down for its own shape, answered so once its session is let in. */
    const turnedDown = async (status: number, reason: string): Promise<Response> =>
      answered(await store.admit(caller, now), () => problem(status, reason));

    const path = new URL(request.url).pathname.split("/").slice(1);
    if (path[0] !== "writings" || path.length > 2) {
      return turnedDown(404, "the only routes are /writings and /writings/<ID>");
    }

    if (path.length === 1) {
      if (request.method !== "GET") {
        return turnedDown(405, "/writings is only read, with GET");
      }
      return answered(await store.list(caller, now), (writings) => Response.json({ writings }));
    }

    const id = parseWritingId(path[1] ?? "");
    if (id === undefined) {
      return turnedDown(404, "a writing's ID is a UUID");
    }
    switch (request.method) {
      case "GET": {
        return answered(await store.read(caller, id, now), (read) =>
          read === undefined
            ? problem(404, "the server has no writing with this ID")
            : new Response(read.bytes, {
                headers: {
                  "Content-Type": "application/octet-stream",
                  "Mai-Revision": read.revision,
                },
              }),
        );
      }
      case "PUT": {
        if (request.headers.get("Content-Type") !== "application/octet-stream") {
          return turnedDown(415, "a sealed writing is sent as application/octet-stream");
        }
        const base = parseBase(request.headers.get("Mai-Base-Revision"));
        if (!base.ok) {
          return turnedDown(400, base.reason);
        }
        const envelope = await parseEnvelope(await request.arrayBuffer());
        if (!envelope.ok) {
          return turnedDown(400, envelope.reason);
        }
        if (envelope.value.id !== id) {
          return turnedDown(400, "the sealed writing's ID is not the one in the path");
        }
        return answered(await store.save(caller, envelope.value, base.value, now), (saved) =>
          Response.json({ revision: saved.revision }, { status: saved.saved ? 200 : 409 }),
        );
      }
      default:
        return turnedDown(405, "a writing is read with GET and saved with PUT");
    }
  },

  async scheduled(_controller, env): Promise<void> {
    await Store.open(env.TURSO_URL, env.TURSO_TOKEN).sweep(Date.now());
  },
} satisfies ExportedHandler<Env>;

function answered<T>(answer: Answer<T>, respond: (value: T) => Response): Response {
  return answer.ok ? respond(answer.value) : refused(answer.refusal);
}

const refusals: Record<Refusal, { status: number; reason: string }> = {
  session: { status: 401, reason: "the session token is unknown, or its session has ended" },
  requests: { status: 429, reason: "the plan's requests for today are used up" },
  lists: { status: 429, reason: "the plan's listings for today are used up" },
  saves: { status: 429, reason: "the plan's saves for today are used up" },
  storage: { status: 429, reason: "the plan's storage for writings is full" },
};

function refused(refusal: Refusal): Response {
  const { status, reason } = refusals[refusal];
  return problem(status, reason);
}

function problem(status: number, reason: string): Response {
  return Response.json({ error: reason }, { status });
}
