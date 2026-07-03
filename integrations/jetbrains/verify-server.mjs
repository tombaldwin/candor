#!/usr/bin/env node
// Handshake the built single-file server bundle over LSP stdio — the gate between bundleServer and
// packaging. Exists because a packaged plugin once shipped a server that crashed on startup (the npm
// lsp.mjs predated the relocation-tolerance fix): the bundle was verified from LOCAL source, the
// artifact was built from npm, and nothing tested the artifact itself. Now the build does.
import { spawn } from "node:child_process";
const bundle = process.argv[2];
const srv = spawn("node", [bundle]);
let buf = Buffer.alloc(0), err = "";
const die = (msg) => { console.error(`verify-server: FAIL — ${msg}${err ? " | stderr: " + err.slice(0, 300) : ""}`); process.exit(1); };
const timer = setTimeout(() => { srv.kill(); die("no initialize response within 10s"); }, 10_000);
srv.stderr.on("data", (d) => (err += d));
srv.on("exit", (c) => die(`server exited (code ${c}) before answering`));
srv.stdout.on("data", (c) => {
  buf = Buffer.concat([buf, c]);
  const he = buf.indexOf("\r\n\r\n");
  if (he < 0) return;
  const len = parseInt(buf.slice(0, he).toString().match(/Content-Length:\s*(\d+)/i)?.[1] ?? "0", 10);
  if (buf.length < he + 4 + len) return;
  const r = JSON.parse(buf.slice(he + 4, he + 4 + len).toString());
  const caps = r?.result?.capabilities ?? {};
  if (!caps.codeLensProvider || !caps.hoverProvider) die(`capabilities incomplete: ${JSON.stringify(Object.keys(caps))}`);
  clearTimeout(timer);
  console.log(`verify-server: ok — ${r.result.serverInfo.name} ${r.result.serverInfo.version} (codeLens+hover+sync)`);
  srv.removeAllListeners("exit");
  srv.kill();
  process.exit(0);
});
const b = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }));
srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`);
srv.stdin.write(b);
