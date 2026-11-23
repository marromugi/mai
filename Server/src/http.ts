import { isJson, type Json } from "./jws";

/** A JSON object sent as `application/json`; undefined for any other body. */
export async function jsonBody(request: Request): Promise<Json | undefined> {
  if (request.headers.get("Content-Type")?.split(";")[0]?.trim() !== "application/json") {
    return undefined;
  }
  try {
    const body: unknown = await request.json();
    return isJson(body) ? body : undefined;
  } catch (error) {
    if (error instanceof SyntaxError) {
      return undefined;
    }
    throw error;
  }
}

export function problem(status: number, reason: string): Response {
  return Response.json({ error: reason }, { status });
}
