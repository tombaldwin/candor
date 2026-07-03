import de.undercouch.gradle.tasks.download.Download

// candor for JetBrains IDEs — a THIN client: all analysis lives in the engines, all LSP logic in the
// bundled single-file candor-lsp server (from the candor-ts npm package). This plugin is a manifest,
// a spawn, and a build hook. See ../AGENT-SURFACE-DESIGN.md (bet 2) + README.md.
plugins {
    id("java")
    id("org.jetbrains.intellij.platform") version "2.17.0"
    id("de.undercouch.download") version "5.6.0"
}

group = "io.poly.candor"
version = providers.gradleProperty("pluginVersion").get()

repositories {
    mavenCentral()
    intellijPlatform { defaultRepositories() }
}

dependencies {
    intellijPlatform {
        create(providers.gradleProperty("platformType").get(), providers.gradleProperty("platformVersion").get())
        // LSP4IJ from the JetBrains Marketplace — the LSP client that works on Community editions too.
        plugin(providers.gradleProperty("lsp4ijVersion").get())
    }
}

java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }

// ── the two embedded artifacts ──────────────────────────────────────────────────────────────────────
// 1. The single-file LSP server: npm-install candor-ts into build/, esbuild lsp.mjs → one ~20KB .mjs.
//    (Requires node+npx on the BUILD machine only; users need node on PATH at runtime — see README.)
val stageServer by tasks.registering(Exec::class) {
    val stage = layout.buildDirectory.dir("server-stage").get().asFile
    outputs.dir(stage.resolve("node_modules/candor-ts"))
    doFirst { stage.mkdirs() }
    workingDir = stage
    commandLine("npm", "install", "--no-save", "--no-audit", "--no-fund", "candor-ts")
}
val bundleServer by tasks.registering(Exec::class) {
    dependsOn(stageServer)
    val stage = layout.buildDirectory.dir("server-stage").get().asFile
    val out = layout.buildDirectory.file("embedded/candor-lsp.mjs").get().asFile
    outputs.file(out)
    workingDir = stage
    commandLine(
        "npx", "-y", "esbuild", "node_modules/candor-ts/lsp.mjs",
        "--bundle", "--platform=node", "--format=esm", "--outfile=${out.absolutePath}",
    )
}

// 2. The JVM engine jar for the build hook (candor needs no jbang/npm knowledge from the user —
//    the plugin runs this jar with the IDE's own JDK after every successful build).
val fetchEngineJar by tasks.registering(Download::class) {
    val v = providers.gradleProperty("candorJavaVersion").get()
    src("https://github.com/tombaldwin/candor-java/releases/download/v$v/candor-java-$v-all.jar")
    dest(layout.buildDirectory.file("embedded/candor-java-all.jar"))
    overwrite(false)
}

// The artifact gate: handshake the BUILT bundle over LSP stdio before it can be packaged. The plugin
// once shipped a startup-crashing server because the verified bundle and the packaged bundle were
// built from different sources — this task makes the packaged one the verified one, by construction.
val verifyServerBundle by tasks.registering(Exec::class) {
    dependsOn(bundleServer)
    val out = layout.buildDirectory.file("embedded/candor-lsp.mjs").get().asFile
    inputs.file(out)
    commandLine("node", "verify-server.mjs", out.absolutePath)
}

tasks.processResources {
    dependsOn(verifyServerBundle)
    from(bundleServer) { into("server") }
    from(fetchEngineJar) { into("engine") }
}

intellijPlatform {
    pluginConfiguration {
        name = "candor: effects & architecture gate"
    }
    // The headless pre-publish gate: JetBrains' Plugin Verifier checks binary compatibility (broken
    // APIs, missing classes) against the pinned target IDE — the same verification the Marketplace
    // runs on upload. One IDE keeps the download bounded; broaden before widening since/until builds.
    pluginVerification {
        ides {
            recommended()   // the IDE releases matching this plugin's since/until builds
        }
    }
}
