#!/usr/bin/env bash
# The VS Code extension's build-and-verify gate (TESTING.md §2/§11): build the artifact, then verify
# THE ARTIFACT — never a lookalike. Gates:
#   1. the staged server package IS the candorTsVersion pin (stage-server.mjs asserts it; re-asserted here)
#   2. the packaged .vsix CONTAINS the server bundle + client bundle + icon + LICENSE + README
#   3. the server bundle EXTRACTED FROM THE .VSIX passes the full LSP lifecycle handshake
#      (initialize → initialized → shutdown → exit, clean exit 0)
#   4. drift: every activation event, command, and setting package.json declares appears in README.md,
#      and the extension version tracks the bundled server (major.minor == the pin's, the README claim)
# Staging talks to npm (a build, like the JetBrains gradle chain); the verification itself is local.
set -euo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== build (npm ci + stage pinned server + bundle + package) =="
if [ ! -x node_modules/.bin/vsce ] || [ ! -x node_modules/.bin/esbuild ]; then
  npm ci --no-audit --no-fund
fi
npm run --silent build
PIN=$(node -p 'require("./package.json").candorTsVersion')
VERSION=$(node -p 'require("./package.json").version')
rm -f candor-vscode-*.vsix
npm run --silent package
VSIX="candor-vscode-$VERSION.vsix"

echo "== gate 1: the staged server is the pin ($PIN) =="
STAGED=$(node -p 'require("./build/server-stage/node_modules/candor-ts/package.json").version')
if [ "$STAGED" = "$PIN" ]; then ok "staged candor-ts $STAGED == pin"; else fail "staged candor-ts $STAGED != pin $PIN"; fi

echo "== gate 2: the .vsix contains what we ship =="
if [ -f "$VSIX" ]; then ok "$VSIX exists"; else fail "$VSIX was not produced"; exit 1; fi
LISTING=$(unzip -l "$VSIX")
# NOTE: vsce renames inside the archive — LICENSE → LICENSE.txt, README.md → readme.md.
for f in extension/dist/candor-lsp.mjs extension/dist/extension.cjs extension/icon.png \
         extension/LICENSE.txt extension/LICENSE-MIT extension/LICENSE-APACHE extension/readme.md \
         extension/package.json; do
  if echo "$LISTING" | grep -q " $f\$"; then ok "contains $f"; else fail "missing $f"; fi
done
for f in extension/node_modules extension/src/ extension/build/; do
  if echo "$LISTING" | grep -q "$f"; then fail "ships build litter: $f"; else ok "no $f inside"; fi
done

echo "== gate 3: the server bundle FROM the .vsix passes the LSP lifecycle handshake =="
unzip -o -q -d "$TMP" "$VSIX" extension/dist/candor-lsp.mjs
if node scripts/verify-server.mjs "$TMP/extension/dist/candor-lsp.mjs"; then
  ok "extracted bundle: initialize/initialized/shutdown/exit clean"
else
  fail "extracted bundle failed the handshake"
fi

echo "== gate 4: manifest <-> README drift =="
node - <<'EOF' && ok "activation events, command, settings, version-tracks-pin all hold" || fail "drift between package.json and README.md (see above)"
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
const readme = fs.readFileSync("README.md", "utf8");
let bad = 0;
const need = (s, why) => { if (!readme.includes(s)) { console.error(`  drift: README does not mention ${why}: ${s}`); bad++; } };
for (const ev of pkg.activationEvents.filter((e) => e.startsWith("workspaceContains")))
  need(ev.replace(/^workspaceContains:/, "workspaceContains:"), "activation event");
for (const c of pkg.contributes.commands) need(c.command, "command");
for (const key of Object.keys(pkg.contributes.configuration.properties)) need(key, "setting");
const mm = (v) => v.split(".").slice(0, 2).join(".");
if (mm(pkg.version) !== mm(pkg.candorTsVersion)) {
  console.error(`  drift: extension ${pkg.version} does not track the server pin ${pkg.candorTsVersion} (major.minor)`);
  bad++;
}
process.exit(bad ? 1 : 0);
EOF

echo
echo "test-vscode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
