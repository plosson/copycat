// Copycat: real files on the macOS clipboard. github.com/plosson/copycat
(function (g) {
  var BASE = "http://127.0.0.1:47823";
  // Chrome's local network permission (name varies by version).
  var PERMISSIONS = ["loopback-network", "local-network-access"];

  function create(env) {
    env = env || {};
    var nav = env.navigator || g.navigator;
    function call(path, init, ms) {
      var abort = new AbortController();
      var timer = ms && setTimeout(function () { abort.abort(); }, ms);
      init.signal = abort.signal;
      init.targetAddressSpace = "loopback";
      return (env.fetch || g.fetch)(BASE + path, init)
        .then(function (r) { return r.json(); })
        .finally(function () { clearTimeout(timer); });
    }
    async function localNetworkState() {
      var p = nav && nav.permissions;
      for (var i = 0; p && i < PERMISSIONS.length; i++) {
        try { return (await p.query({ name: PERMISSIONS[i] })).state; } catch (e) {}
      }
      return null;
    }
    return {
      create: create,
      // "ready" | "unknown" | "absent". Never triggers Chrome's prompt.
      status: async function () {
        if ((await localNetworkState()) === "prompt") return "unknown";
        try {
          var reply = await call("/ping", { method: "GET" }, 1000);
          return reply && reply.app === "copycat" ? "ready" : "absent";
        } catch (e) { return "absent"; }
      },
      // Call from a click handler. Resolves to { ok: true } or { ok: false, error }.
      copy: async function (url, hints) {
        hints = hints || {};
        try {
          var reply = await call("/copy", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ url: url, type: hints.type, name: hints.name })
          });
          return reply && typeof reply.ok === "boolean" ? reply : { ok: false, error: "absent" };
        } catch (e) { return { ok: false, error: "absent" }; }
      }
    };
  }

  g.Copycat = create();
})(globalThis);
