package io.poly.candor.ide;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.roots.CompilerModuleExtension;
import com.intellij.openapi.roots.ModuleRootManager;
import com.intellij.openapi.module.ModuleManager;
import com.intellij.task.ProjectTaskContext;
import com.intellij.task.ProjectTaskListener;
import com.intellij.task.ProjectTaskManager;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;

/**
 * The JVM freshness loop (AGENT-SURFACE-DESIGN bet 2, the IntelliJ sweetener): after every successful
 * build, run the BUNDLED candor-java engine over the compiled output with the IDE's own JVM, writing
 * {@code <root>/.candor/report.json} — the report the LSP server renders. Zero external tooling: no
 * jbang, no npm knowledge; the analysis engine rides inside the plugin (~1 MB jar).
 *
 * <p>The scan runs on a background thread (it is Fs-only by candor's own §7.12 self-boundary) and only
 * for projects that OPTED IN by carrying a {@code .candor/} directory — the plugin never writes into a
 * repo that hasn't adopted candor.
 */
public class CandorBuildListener implements ProjectTaskListener {
    private static final Logger LOG = Logger.getInstance(CandorBuildListener.class);

    @Override
    public void finished(ProjectTaskContext context, ProjectTaskManager.Result result) {
        if (result.hasErrors()) return;
        Project project = context.getProject();
        String base = project.getBasePath();
        if (base == null || !Files.isDirectory(Path.of(base, ".candor"))) return;   // opt-in marker

        List<String> outputRoots = new ArrayList<>();
        for (var module : ModuleManager.getInstance(project).getModules()) {
            CompilerModuleExtension ext = ModuleRootManager.getInstance(module)
                    .getModuleExtension(CompilerModuleExtension.class);
            if (ext != null && ext.getCompilerOutputUrl() != null) {
                String url = ext.getCompilerOutputUrl();
                if (url.startsWith("file://")) outputRoots.add(url.substring("file://".length()));
            }
        }
        if (outputRoots.isEmpty()) return;

        ApplicationManager.getApplication().executeOnPooledThread(() -> refreshReport(base, outputRoots));
    }

    private void refreshReport(String base, List<String> outputRoots) {
        try {
            Path jar = extractedEngineJar();
            String javaBin = Path.of(System.getProperty("java.home"), "bin", "java").toString();
            // One report per project v1: scan the first output root (multi-module → a report set is the
            // follow-up; the LSP merges reports under one prefix already).
            Process p = new ProcessBuilder(javaBin, "-jar", jar.toString(), outputRoots.get(0),
                    "--json", Path.of(base, ".candor", "report.json").toString())
                    .directory(Path.of(base).toFile())
                    .redirectErrorStream(true)
                    .start();
            p.getInputStream().readAllBytes();
            p.waitFor();
            LOG.info("candor: report refreshed after build (exit " + p.exitValue() + ")");
        } catch (Exception e) {
            LOG.warn("candor: post-build report refresh failed", e);
        }
    }

    /** Extract the bundled engine jar once (idempotent, same pattern as the server). */
    static Path extractedEngineJar() throws IOException {
        Path dir = Path.of(System.getProperty("java.io.tmpdir"), "candor-intellij");
        Path out = dir.resolve("candor-java-all.jar");
        if (Files.exists(out) && Files.size(out) > 0) return out;
        try (InputStream in = CandorBuildListener.class.getResourceAsStream("/engine/candor-java-all.jar")) {
            if (in == null) throw new IOException("bundled engine missing from plugin resources");
            Files.createDirectories(dir);
            Files.copy(in, out, StandardCopyOption.REPLACE_EXISTING);
        }
        return out;
    }
}
