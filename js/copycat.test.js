import { describe, expect, test } from "bun:test";
import { readFileSync, statSync } from "node:fs";
import Copycat from "./copycat.mjs";

const json = (body) => new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });

function fakeFetch(answer) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    return answer(url, init);
  };
  return { fetch, calls };
}

const permissions = (state) => ({ permissions: { query: async () => ({ state }) } });
const noPermissionApi = {};
const unknownPermissionName = { permissions: { query: async () => { throw new TypeError("bad name"); } } };

describe("status()", () => {
  test("Copycat not running: connection refused → absent", async () => {
    const { fetch } = fakeFetch(() => { throw new TypeError("Failed to fetch"); });
    expect(await Copycat.create({ fetch, navigator: noPermissionApi }).status()).toBe("absent");
  });

  test("ping that never answers times out after about a second → absent", async () => {
    const fetch = (url, init) => new Promise((_, reject) => {
      init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    });
    const start = Date.now();
    expect(await Copycat.create({ fetch, navigator: noPermissionApi }).status()).toBe("absent");
    expect(Date.now() - start).toBeGreaterThanOrEqual(900);
    expect(Date.now() - start).toBeLessThan(2000);
  });

  test("another program answers with HTML → absent", async () => {
    const { fetch } = fakeFetch(() => new Response("<html>hello</html>"));
    expect(await Copycat.create({ fetch, navigator: noPermissionApi }).status()).toBe("absent");
  });

  test("another program answers with JSON that is not Copycat's → absent", async () => {
    for (const body of [{ app: "other" }, { ok: true }, null, "copycat", [1, 2]]) {
      const { fetch } = fakeFetch(() => json(body));
      expect(await Copycat.create({ fetch, navigator: noPermissionApi }).status()).toBe("absent");
    }
  });

  test("Chrome permission state prompt → unknown, and no request is made", async () => {
    const { fetch, calls } = fakeFetch(() => json({ app: "copycat" }));
    expect(await Copycat.create({ fetch, navigator: permissions("prompt") }).status()).toBe("unknown");
    expect(calls.length).toBe(0);
  });

  test("permission granted and Copycat answers → ready", async () => {
    const { fetch, calls } = fakeFetch(() => json({ app: "copycat", version: "1.0.0", permission: "prompt" }));
    expect(await Copycat.create({ fetch, navigator: permissions("granted") }).status()).toBe("ready");
    expect(calls[0].url).toBe("http://127.0.0.1:47823/ping");
    expect(calls[0].init.targetAddressSpace).toBe("loopback");
  });

  test("permission denied → pings, and the failed ping gives absent", async () => {
    const { fetch } = fakeFetch(() => { throw new TypeError("Failed to fetch"); });
    expect(await Copycat.create({ fetch, navigator: permissions("denied") }).status()).toBe("absent");
  });

  test("browser that does not know the permission name pings directly", async () => {
    const { fetch, calls } = fakeFetch(() => json({ app: "copycat" }));
    expect(await Copycat.create({ fetch, navigator: unknownPermissionName }).status()).toBe("ready");
    expect(calls.length).toBe(1);
  });
});

describe("copy()", () => {
  test("network error → absent", async () => {
    const { fetch } = fakeFetch(() => { throw new TypeError("Failed to fetch"); });
    expect(await Copycat.create({ fetch }).copy("https://a.com/a.gif")).toEqual({ ok: false, error: "absent" });
  });

  test("reply that is not Copycat's → absent", async () => {
    const { fetch } = fakeFetch(() => new Response("<html></html>"));
    expect(await Copycat.create({ fetch }).copy("https://a.com/a.gif")).toEqual({ ok: false, error: "absent" });
  });

  test("passes Copycat's error through", async () => {
    const { fetch } = fakeFetch(() => json({ ok: false, error: "denied" }));
    expect(await Copycat.create({ fetch }).copy("https://a.com/a.gif")).toEqual({ ok: false, error: "denied" });
  });

  test("posts url and hints as JSON", async () => {
    const { fetch, calls } = fakeFetch(() => json({ ok: true }));
    expect(await Copycat.create({ fetch }).copy("https://a.com/a.gif", { type: "image/gif", name: "a.gif" })).toEqual({ ok: true });
    expect(calls[0].url).toBe("http://127.0.0.1:47823/copy");
    expect(calls[0].init.method).toBe("POST");
    expect(JSON.parse(calls[0].init.body)).toEqual({ url: "https://a.com/a.gif", type: "image/gif", name: "a.gif" });
  });

  test("a slow copy (prompt + download) is not cut off by a timeout", async () => {
    const { fetch } = fakeFetch(() => new Promise((resolve) => setTimeout(() => resolve(json({ ok: true })), 1500)));
    expect(await Copycat.create({ fetch }).copy("https://a.com/a.gif")).toEqual({ ok: true });
  });
});

describe("file", () => {
  test("is under 2 KB", () => {
    expect(statSync(new URL("./copycat.js", import.meta.url)).size).toBeLessThan(2048);
  });

  test("works as a classic script and sets window.Copycat", () => {
    const source = readFileSync(new URL("./copycat.js", import.meta.url), "utf8");
    const fakeWindow = {};
    new Function("globalThis", source)(fakeWindow);
    expect(typeof fakeWindow.Copycat.status).toBe("function");
    expect(typeof fakeWindow.Copycat.copy).toBe("function");
  });
});
