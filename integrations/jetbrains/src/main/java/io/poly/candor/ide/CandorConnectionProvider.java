package io.poly.candor.ide;

import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.project.Project;
import com.redhat.devtools.lsp4ij.server.ProcessStreamConnectionProvider;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.List;

/**
 * Spawns {@code node <extracted candor-lsp.mjs>} for the project. The server is the single-file esbuild
 * bundle of candor-ts's lsp.mjs, shipped inside this plugin (resources/server/candor-lsp.mjs) and
 * extracted once per plugin version to the system cache — the same server every other editor runs, so
 * no IDE-specific logic can drift from the spec.
 *
 * <p>Node is the one runtime prerequisite (most dev machines have it; the plugin description says so).
 * Resolution: $CANDOR_NODE, else "node" on PATH. A missing node surfaces as LSP4IJ's start failure with
 * this command line visible — actionable, not silent.
 */
public class CandorConnectionProvider extends ProcessStreamConnectionProvider {
    private static final Logger LOG = Logger.getInstance(CandorConnectionProvider.class);

    public CandorConnectionProvider(Project project) {
        String node = System.getenv().getOrDefault("CANDOR_NODE", "node");
        Path server = extractedServer();
        setCommands(List.of(node, server.toString()));
        if (project.getBasePath() != null) {
            setWorkingDirectory(project.getBasePath());   // the server discovers <root>/.candor/* itself
        }
    }

    /** Extract the bundled server to a stable per-plugin-version path (idempotent). */
    static Path extractedServer() {
        Path dir = Path.of(System.getProperty("java.io.tmpdir"), "candor-intellij");
        Path out = dir.resolve("candor-lsp.mjs");
        try (InputStream in = CandorConnectionProvider.class.getResourceAsStream("/server/candor-lsp.mjs")) {
            if (in == null) throw new IOException("bundled server missing from plugin resources");
            Files.createDirectories(dir);
            Files.copy(in, out, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            LOG.warn("candor: could not extract the bundled language server", e);
        }
        return out;
    }
}
