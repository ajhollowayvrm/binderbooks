/* Guards on the Lambda's request routing.

   `aws/index.mjs` cannot be imported here: it constructs a DynamoDB client at
   module scope, and the AWS SDK is not a dependency of this project — the
   Lambda runtime supplies it. So these tests re-implement the one-line route
   parser and check it against the call sites in the source text.

   That is a weaker test than importing the real thing, and it exists because a
   real bug got through without it: `route` was changed to hold the last path
   segment ("sets") while every call site still passed a leading slash
   ("/sets"), so `isGet` could never return true and every card-data route
   answered 404. Nothing caught it — the Lambda has no tests, and the browser
   check ran without a sync token, which short-circuits every card route in the
   client before it reaches the network.

   The proper fix is to extract the pure helpers into a module that both the
   Lambda and these tests import, and add it to the deploy zip. That touches
   deploy.sh and deploy.ps1 together, so it is left for a deliberate change. */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// vitest runs from the repo root, and `import.meta.url` is not a file: URL
// under the jsdom environment
const SRC = readFileSync(resolve(process.cwd(), "aws/index.mjs"), "utf8");

// the parser as index.mjs defines it — keep these two in step
const routeOf = (path, stage) => {
  const rawPath = (path || "/").replace(/\/+$/, "");
  const staged = stage && stage !== "$default"
    && (rawPath === `/${stage}` || rawPath.startsWith(`/${stage}/`));
  return (staged ? rawPath.slice(stage.length + 1) : rawPath).split("/").pop();
};

describe("route parsing", () => {
  it("reduces a request path to its last segment", () => {
    expect(routeOf("/sets")).toBe("sets");
    expect(routeOf("/prices")).toBe("prices");
    expect(routeOf("/identify")).toBe("identify");
  });

  it("reads the ledger's own root path as an empty route", () => {
    // the client calls SYNC_URL itself for the ledger, which is "/"
    expect(routeOf("/")).toBe("");
    expect(routeOf("")).toBe("");
    expect(routeOf("//")).toBe("");
  });

  it("tolerates a trailing slash", () => {
    expect(routeOf("/sets/")).toBe("sets");
  });

  it("strips a named stage so the ledger root stays the root", () => {
    /* Behind a named stage the ledger's own root is "/prod". Without the
       strip, route would read "prod", the root-only guard would reject it, and
       every ledger GET and PUT would 404 on a config change alone. */
    expect(routeOf("/prod", "prod")).toBe("");
    expect(routeOf("/prod/prices", "prod")).toBe("prices");
    expect(routeOf("/prod/identify", "prod")).toBe("identify");
  });

  it("leaves the path alone on the $default stage, which is not prefixed", () => {
    expect(routeOf("/", "$default")).toBe("");
    expect(routeOf("/prices", "$default")).toBe("prices");
  });

  it("does not strip a route that merely starts with the stage name", () => {
    // a stage called "se" must not turn "/sets" into "ts"
    expect(routeOf("/sets", "se")).toBe("sets");
  });

  it("does not read an unknown path as the ledger", () => {
    // this is what let any authenticated GET return the whole ledger
    expect(routeOf("/anything")).not.toBe("");
  });
});

describe("the source agrees with the parser", () => {
  /* `route` holds a bare segment, so a call site that passes "/sets" can never
     match. This is the exact regression described at the top of the file. */
  it("passes bare route names to isGet, never a leading slash", () => {
    const calls = [...SRC.matchAll(/isGet\((["'])(.*?)\1\)/g)].map((m) => m[2]);
    expect(calls.length).toBeGreaterThan(0);
    const slashed = calls.filter((c) => c.startsWith("/"));
    expect(slashed).toEqual([]);
  });

  it("covers every card-data route the client calls", () => {
    // src/App.jsx calls these six through cardFetch
    const calls = new Set([...SRC.matchAll(/isGet\((["'])(.*?)\1\)/g)].map((m) => m[2]));
    for (const r of ["sets", "prices", "catalog", "search", "graded", "history"])
      expect(calls).toContain(r);
  });

  it("compares the route by equality, not by endsWith", () => {
    // `endsWith("/sets")` also matched "/anything/sets"
    expect(SRC).toMatch(/const isGet = \(p\) => method === "GET" && route === p;/);
    expect(SRC).not.toMatch(/rawPath\?\.endsWith/);
  });

  it("refuses an unset, empty or literal-'undefined' sync token", () => {
    // String(undefined) is "undefined", which the old compare authenticated
    const m = SRC.match(/const tokenReady = \(\) => \{[\s\S]*?\n\};/);
    expect(m).toBeTruthy();
    expect(m[0]).toContain('t !== "undefined"');
    expect(m[0]).toContain("t.length > 0");
  });

  it("measures the ledger in bytes, not in string length", () => {
    expect(SRC).toContain('Buffer.byteLength(s, "utf8")');
    expect(SRC).not.toMatch(/data\.length > MAX_BYTES/);
  });
});
