// candor for VS Code (and its VSIX-compatible forks — Cursor, Windsurf) — a THIN LSP client: all
// analysis lives in the engines, all LSP logic in the bundled single-file candor-lsp server (staged at
// build time from the PINNED candor-ts npm package — the `candorTsVersion` field in package.json).
// This extension is a manifest, a spawn, and two settings — the same shape as the JetBrains plugin
// (../jetbrains). See ../AGENT-SURFACE-DESIGN.md (bet 2) + README.md.
"use strict";
const path = require("node:path");
const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

// The report is language-agnostic; attach to the family's languages (the same set as the JetBrains
// plugin.xml mappings). A file with no report entries simply gets no lenses — the server is silent there.
const LANGUAGES = ["java", "kotlin", "javascript", "javascriptreact", "typescript", "typescriptreact", "rust", "swift"];

let client;

function serverEnv() {
  const env = { ...process.env };
  const policyPath = vscode.workspace.getConfiguration("candor").get("policyPath", "");
  if (policyPath) {
    const folder = vscode.workspace.workspaceFolders?.[0];
    env.CANDOR_POLICY = path.isAbsolute(policyPath) || !folder
      ? policyPath
      : path.join(folder.uri.fsPath, policyPath);
  }
  return env;
}

async function startClient(context) {
  if (client) return;
  // The bundled server runs on VS Code's OWN Node: the languageclient module transport spawns
  // process.execPath with ELECTRON_RUN_AS_NODE — no system node/npm required at runtime.
  const server = {
    module: context.asAbsolutePath(path.join("dist", "candor-lsp.mjs")),
    transport: TransportKind.stdio,
    options: { env: serverEnv() },
  };
  client = new LanguageClient(
    "candor", // the id `candor.trace.server` keys off
    "candor",
    { run: server, debug: server },
    { documentSelector: LANGUAGES.map((language) => ({ scheme: "file", language })) },
  );
  await client.start();
}

async function stopClient() {
  const c = client;
  client = undefined;
  if (c) await c.stop();
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("candor.start", () => startClient(context)),
    // CANDOR_POLICY is process env on the server — a policyPath change needs a server restart to bite.
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (e.affectsConfiguration("candor.policyPath") && client) {
        await stopClient();
        await startClient(context);
      }
    }),
  );
  // Activation is already gated (workspaceContains `.candor` markers, or the explicit `candor: start`
  // command) — this extension never activates on an arbitrary window, so activation means "start".
  return startClient(context);
}

function deactivate() {
  return stopClient();
}

module.exports = { activate, deactivate };
