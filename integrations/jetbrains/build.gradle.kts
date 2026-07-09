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
// 1. The single-file LSP server: npm-install the PINNED candor-ts into build/, esbuild lsp.mjs → one
//    ~20KB .mjs. (Requires node+npx on the BUILD machine only; users need node at runtime — see README.)
//    The pin is a task INPUT on both stages: without it the tasks were output-only and stayed
//    "up-to-date" forever — a pin bump (or npm publishing a new latest) never re-staged the server.
val candorTsVersion = providers.gradleProperty("candorTsVersion")
val stageServer by tasks.registering(Exec::class) {
    val stage = layout.buildDirectory.dir("server-stage").get().asFile
    inputs.property("candorTsVersion", candorTsVersion)
    outputs.dir(stage.resolve("node_modules/candor-ts"))
    doFirst { stage.mkdirs() }
    workingDir = stage
    commandLine("npm", "install", "--no-save", "--no-audit", "--no-fund", "candor-ts@${candorTsVersion.get()}")
}
val bundleServer by tasks.registering(Exec::class) {
    dependsOn(stageServer)
    val stage = layout.buildDirectory.dir("server-stage").get().asFile
    val out = layout.buildDirectory.file("embedded/candor-lsp.mjs").get().asFile
    inputs.property("candorTsVersion", candorTsVersion)
    outputs.file(out)
    workingDir = stage
    commandLine(
        "npx", "-y", "esbuild", "node_modules/candor-ts/lsp.mjs",
        "--bundle", "--platform=node", "--format=esm", "--outfile=${out.absolutePath}",
    )
}

// 2. The JVM engine jar for the build hook (candor needs no jbang/npm knowledge from the user —
//    the plugin runs this jar with the IDE's own JDK after every successful build). The dest is
//    VERSIONED: with a versionless dest + overwrite(false), bumping candorJavaVersion silently kept
//    shipping the previously-downloaded jar (a 0.8.2 embed under a 0.8.4 pin, live on disk).
val candorJavaVersion = providers.gradleProperty("candorJavaVersion")
val fetchEngineJar by tasks.registering(Download::class) {
    val v = candorJavaVersion.get()
    src("https://github.com/tombaldwin/candor-java/releases/download/v$v/candor-java-$v-all.jar")
    dest(layout.buildDirectory.file("embedded/candor-java-$v-all.jar"))
    overwrite(false)   // safe now: a pin bump changes the filename, so it can't pin-skew the embed
}

// The embed gate: the staged jar must SAY it is the pinned version (`--version` self-reports) before it
// can be packaged — a stale/corrupt download fails the build here, not in a user's IDE.
val verifyEngineJar by tasks.registering {
    dependsOn(fetchEngineJar)
    val v = candorJavaVersion.get()
    val jar = layout.buildDirectory.file("embedded/candor-java-$v-all.jar")
    inputs.file(jar)
    doLast {
        val p = ProcessBuilder("java", "-jar", jar.get().asFile.absolutePath, "--version")
            .redirectErrorStream(true).start()
        val out = p.inputStream.readBytes().decodeToString()
        val rc = p.waitFor()
        // match the SELF-REPORT line ("candor-java 0.8.4 (spec …)"), not just the version substring —
        // java's "Invalid or corrupt jarfile <path>" error contains the version via the filename.
        if (rc != 0 || !out.contains("candor-java $v")) throw GradleException(
            "staged engine jar does not report the pinned version $v (exit $rc) — stale/corrupt embed?\n--version said:\n$out")
    }
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
    dependsOn(verifyServerBundle, verifyEngineJar)
    from(bundleServer) { into("server") }
    // the resource path stays versionless (CandorBuildListener reads /engine/candor-java-all.jar);
    // only the staged file on disk is versioned (that's what makes the pin bump re-download).
    from(fetchEngineJar) { into("engine"); rename { "candor-java-all.jar" } }
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
