import { describe, expect, it } from "vitest";
import { Challenges, challengeLifetime } from "../src/challenges";
import { RefreshTokens } from "../src/refresh-tokens";

const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
const now = Date.UTC(2026, 10, 24, 12);

describe("a challenge", () => {
  it("lasts five minutes from when it is given out", async () => {
    const challenges = new Challenges(key);
    const value = await challenges.issue(now);
    expect(value.split(".")[0]).toBe(String(now + 5 * 60 * 1000));
    expect(challengeLifetime).toBe(5 * 60 * 1000);
    expect(await challenges.check(value, now + challengeLifetime - 1)).toBeDefined();
    expect(await challenges.check(value, now + challengeLifetime)).toBeUndefined();
  });

  it("needs a CHALLENGE_KEY of 32 bytes or more", async () => {
    const short = btoa(String.fromCharCode(...new Uint8Array(31)));
    await expect(new Challenges(short).issue(now)).rejects.toThrow(/CHALLENGE_KEY/);
  });
});

describe("a sealed refresh token", () => {
  it.each([16, 24, 31, 33])("needs a REFRESH_TOKEN_KEY of exactly 32 bytes, not %i", async (n) => {
    const wrong = btoa(String.fromCharCode(...new Uint8Array(n)));
    await expect(new RefreshTokens(wrong).seal("token", "account")).rejects.toThrow(
      /REFRESH_TOKEN_KEY/,
    );
  });
});
