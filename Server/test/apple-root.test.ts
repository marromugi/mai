import { describe, expect, it } from "vitest";
import { appleRootCaG3, appleRootCaG3Der } from "../src/apple-root";
import { appleOids, issued } from "../src/app-store";
import { readCertificate } from "../src/der";

/**
 * Apple Worldwide Developer Relations CA - G6, from
 * https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer: the intermediate in the x5c of
 * App Store data.
 */
const wwdrG6 = Uint8Array.from(
  atob(
    "MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBD" +
      "QSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkG" +
      "A1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2" +
      "ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIElu" +
      "Yy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT" +
      "8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIG" +
      "A1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsG" +
      "AQUFBzABhipodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0" +
      "cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1Ud" +
      "DwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXuf" +
      "QB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0n" +
      "DGg=",
  ),
  (character) => character.charCodeAt(0),
);

describe("the pinned root", () => {
  it("is Apple Root CA - G3, by the fingerprint Apple publishes", async () => {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", appleRootCaG3Der));
    expect(Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")).toBe(
      "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    );
  });

  it("reads as a P-384 certificate authority that signed itself", async () => {
    expect(appleRootCaG3.curve).toBe("P-384");
    expect(appleRootCaG3.authority).toBe(true);
    expect(await issued(appleRootCaG3, appleRootCaG3)).toBe(true);
  });

  it("signed Apple's real intermediate, which carries the mark the chain check looks for", async () => {
    const intermediate = readCertificate(wwdrG6);
    expect(intermediate).toBeDefined();
    if (intermediate === undefined) {
      return;
    }
    expect(intermediate.authority).toBe(true);
    expect(intermediate.extensions.has(appleOids.intermediate)).toBe(true);
    expect(await issued(intermediate, appleRootCaG3)).toBe(true);
  });

  it("didn't sign the intermediate once a byte of what it signed changes", async () => {
    const changed = wwdrG6.slice();
    // A byte inside the subject's name, part of what the root's signature covers.
    changed[200] = (changed[200] ?? 0) ^ 0x01;
    const intermediate = readCertificate(changed);
    expect(intermediate).toBeDefined();
    expect(intermediate !== undefined && (await issued(intermediate, appleRootCaG3))).toBe(false);
  });
});
