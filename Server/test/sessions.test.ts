import { describe, expect, it } from "vitest";
import { callerOf, newSessionToken } from "../src/sessions";

describe("a session token", () => {
  it("is read back into the session it was made for", async () => {
    const { token, caller } = await newSessionToken();
    expect(await callerOf(`Bearer ${token}`)).toEqual(caller);
  });

  it.each([
    ["something before it", (token: string) => `x${token}`],
    ["something after it", (token: string) => `${token}x`],
    ["a secret one character short", (token: string) => token.slice(0, -1)],
    ["a session ID in capitals", (token: string) => token.toUpperCase().replace("S1.", "s1.")],
  ])("isn't read with %s", async (_, change) => {
    const { token } = await newSessionToken();
    expect(await callerOf(`Bearer ${change(token)}`)).toBeUndefined();
  });
});
