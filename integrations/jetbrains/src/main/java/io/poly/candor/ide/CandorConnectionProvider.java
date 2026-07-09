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
 * re-extracted to a stable tmp path on every server start (REPLACE_EXISTING — so a plugin update can
 * never serve a stale bundle) — the same server every other editor runs, so no IDE-specific logic can
 * drift from the spec.
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

    /**
     * Extract the bundled server to a stable tmp path, replacing any previous copy (idempotent per start).
     * A failed extraction THROWS — returning the path anyway would hand LSP4IJ a nonexistent file and
     * surface as an opaque node startup error instead of the actual cause.
     */
    static Path extractedServer() {
        Path dir = Path.of(System.getProperty("java.io.tmpdir"), "candor-intellij");
        Path out = dir.resolve("candor-lsp.mjs");
        try (InputStream in = CandorConnectionProvider.class.getResourceAsStream("/server/candor-lsp.mjs")) {
            if (in == null) throw new IOException("bundled server missing from plugin resources");
            Files.createDirectories(dir);
            Files.copy(in, out, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            String msg = "candor: could not extract the bundled language server to " + out
                    + " — check that the temp directory is writable, or reinstall the plugin";
            LOG.error(msg, e);
            throw new IllegalStateException(msg, e);
        }
        return out;
    }
}
