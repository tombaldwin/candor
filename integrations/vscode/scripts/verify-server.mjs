#!/usr/bin/env node
// Handshake a built single-file server bundle over LSP stdio — the gate between staging and packaging.
// Adapted from ../../jetbrains/verify-server.mjs (which exists because a packaged plugin once shipped a
// server that crashed on startup: the bundle was verified from LOCAL source, the artifact was built
// from npm, and nothing tested the artifact itself). This version runs the FULL lifecycle —
// initialize → initialized → shutdown → exit — and requires a clean exit 0, plus the capability floor
// (codeLens + hover). codeActionProvider is reported informationally: the whatif code-action lands
// with a future candor-ts pin, and this line is how a pin bump proves it arrived un-filtered.
import { spawn } from "node:child_process";

const bundle = process.argv[2];
if (!bundle) { console.error("usage: verify-server.mjs <bundle.mjs>"); process.exit(1); }

const srv = spawn(process.execPath, [bundle]);
let buf = Buffer.alloc(0), err = "", stage = "initialize", serverLine = "";
const die = (msg) => {
  console.error(`verify-server: FAIL — ${msg}${err ? " | stderr: " + err.slice(0, 300) : ""}`);
  try { srv.kill(); } catch { /* already gone */ }
  process.exit(1);
};
const timer = setTimeout(() => die(`handshake did not complete within 10s (stage: ${stage})`), 10_000);
const send = (msg) => {
  const b = Buffer.from(JSON.stringify(msg));
  srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`);
  srv.stdin.write(b);
};

srv.stderr.on("data", (d) => (err += d));
srv.on("exit", (code) => {
  if (stage !== "exited") return die(`server exited (code ${code}) before the handshake completed (stage: ${stage})`);
  if (code !== 0) return die(`server exited nonzero (${code}) after the exit notification`);
  clearTimeout(timer);
  console.log(`verify-server: ok — ${serverLine}`);
  process.exit(0);
});
srv.stdout.on("data", (c) => {
  buf = Buffer.concat([buf, c]);
  for (;;) {
    const he = buf.indexOf("\r\n\r\n");
    if (he < 0) return;
    const len = parseInt(buf.slice(0, he).toString().match(/Content-Length:\s*(\d+)/i)?.[1] ?? "0", 10);
    if (buf.length < he + 4 + len) return;
    const msg = JSON.parse(buf.slice(he + 4, he + 4 + len).toString());
    buf = buf.slice(he + 4 + len);
    if (msg.id === 1 && stage === "initialize") {
      const caps = msg.result?.capabilities ?? {};
      if (!caps.codeLensProvider || !caps.hoverProvider) return die(`capabilities incomplete: ${JSON.stringify(Object.keys(caps))}`);
      const codeAction = caps.codeActionProvider ? "codeAction" : "no codeAction yet (whatif rides the next candor-ts pin)";
      serverLine = `${msg.result.serverInfo?.name} ${msg.result.serverInfo?.version} — codeLens+hover+sync; ${codeAction}; clean shutdown`;
      stage = "shutdown";
      send({ jsonrpc: "2.0", method: "initialized", params: {} });
      send({ jsonrpc: "2.0", id: 2, method: "shutdown", params: null });
    } else if (msg.id === 2 && stage === "shutdown") {
      stage = "exited";
      send({ jsonrpc: "2.0", method: "exit" });
    }
    // anything else (window/logMessage etc.) is fine to skip
  }
});
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
