package io.poly.candor.ide;

import com.intellij.openapi.project.Project;
import com.redhat.devtools.lsp4ij.LanguageServerFactory;
import com.redhat.devtools.lsp4ij.server.StreamConnectionProvider;
import org.jetbrains.annotations.NotNull;

/** The LSP4IJ entry point: spawn the bundled single-file candor-lsp server for this project. */
public class CandorLanguageServerFactory implements LanguageServerFactory {
    @Override
    public @NotNull StreamConnectionProvider createConnectionProvider(@NotNull Project project) {
        return new CandorConnectionProvider(project);
    }
}
