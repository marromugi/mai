import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createClient } from "@libsql/client/web";

/**
 * Starts a libSQL server (`sqld`, the server `turso dev` runs) on an empty database holding
 * `schema.sql` and the tests' plans, for the whole run, and removes it afterwards.
 */
export default async function setup(): Promise<() => Promise<void>> {
  const port = process.env["MAI_TEST_SQLD_PORT"];
  if (port === undefined) {
    throw new Error("vitest.config.ts sets MAI_TEST_SQLD_PORT before the run starts");
  }
  const directory = await mkdtemp(join(tmpdir(), "mai-sqld-"));
  const sqld = spawn(
    "sqld",
    ["--no-welcome", "--http-listen-addr", `127.0.0.1:${port}`, "--db-path", join(directory, "db")],
    { stdio: "inherit" },
  );
  const exited = new Promise<void>((resolve) => sqld.once("close", () => resolve()));
  const stop = async (): Promise<void> => {
    sqld.kill();
    await exited;
    await rm(directory, { recursive: true, force: true });
  };

  const url = `http://127.0.0.1:${port}`;
  try {
    await waitUntilUp(url, sqld);
    const client = createClient({ url });
    await client.executeMultiple(await readFile(new URL("../schema.sql", import.meta.url), "utf8"));
    // Each is sold as a product of its own name.
    await client.execute(`INSERT INTO plans VALUES
      ('test-daily', 'test-daily', 1000000, 1000, 4, 2, 2),
      ('test-storage', 'test-storage', 300, 1000, 1000, 1000, 1000),
      ('test-count', 'test-count', 1000000, 2, 1000, 1000, 1000)`);
  } catch (error) {
    await stop();
    throw error;
  }
  return stop;
}

async function waitUntilUp(url: string, sqld: ChildProcess): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (sqld.exitCode !== null || sqld.signalCode !== null) {
      throw new Error("sqld stopped before it answered; is it installed (Server/README.md)?");
    }
    try {
      if ((await fetch(`${url}/health`)).ok) {
        return;
      }
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`sqld didn't answer at ${url} within 10 seconds`);
}
