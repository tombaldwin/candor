#!/usr/bin/env bash
# Reproduce the candor development environment on a fresh macOS machine.
#
# WHY A SCRIPT. The environment is not "clone a repo": it is SEVEN sibling repos, five language
# toolchains, two rust toolchains with specific components, and a dispatcher symlink — and the tooling
# resolves its siblings by RELATIVE PATH (`$HERE/../../candor-rust` in conformance/run.sh,
# `$(dirname $0)/../..` in bin/probe-causes.sh). Get the layout wrong and the failure is not "not found",
# it is a conformance run that silently covers fewer engines.
#
# Re-runnable: every step checks before it acts, so running it twice is safe and running it after a
# partial failure resumes rather than restarts.
#
# Usage:  bash bin/bootstrap-dev.sh [--with-corpora] [--check]
#           --with-corpora   also clone the read-only real-world corpora (pollen, uflexi)
#           --check          run the full verification at the end (slow: builds + conformance)
set -uo pipefail

ROOT="${CANDOR_DEV_ROOT:-$HOME/git}"
REPOS=(candor candor-spec candor-rust candor-java candor-ts candor-swift candor-agents)
WITH_CORPORA=0; RUN_CHECK=0
for a in "$@"; do
  case "$a" in
    --with-corpora) WITH_CORPORA=1 ;;
    --check) RUN_CHECK=1 ;;
    *) echo "bootstrap-dev: unknown flag $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ✔ %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*"; }
die()  { printf '   ✘ %s\n' "$*" >&2; exit 2; }

# ── 0. preconditions ────────────────────────────────────────────────────────────────────────────────
say "preconditions"
[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS; on Linux candor-swift will not build and
        conformance covers four engines — see BACKLOG before going that route"
xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools missing — run: xcode-select --install"
ok "xcode tools: $(xcode-select -p)"
command -v brew >/dev/null || die "Homebrew missing — https://brew.sh"
ok "homebrew: $(brew --version | head -1)"
command -v git >/dev/null || die "git missing"
# SSH to GitHub: every remote is git@github.com, so a fresh box with no key fails at the FIRST clone
# rather than after twenty minutes of toolchain installs. Check it up front.
#
# CAPTURE THEN MATCH — never `ssh … | grep`. `ssh -T git@github.com` exits 1 even on SUCCESS ("you've
# successfully authenticated, but GitHub does not provide shell access"), and with `set -o pipefail` that
# non-zero overrides grep's 0, so the pipeline form reports NO AUTH on precisely the machines where auth
# works. Shipped that way and it failed on the first real box; the reply text is the only signal here.
GH_REPLY="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
case "$GH_REPLY" in
  *"successfully authenticated"*) ok "github ssh auth (${GH_REPLY%%!*}!)" ;;
  *) die "no SSH auth to github.com — add a key (ssh-keygen; gh auth login; or copy one over) and re-run.
        github replied: ${GH_REPLY:-<nothing>}" ;;
esac

# ── 1. the seven repos, as SIBLINGS ─────────────────────────────────────────────────────────────────
say "repos under $ROOT (they MUST be siblings — the tooling resolves ../../<repo>)"
mkdir -p "$ROOT"
for r in "${REPOS[@]}"; do
  # worktree-safe: `-d "$ROOT/$r/.git"` is FALSE for a git worktree, so bootstrap tried to clone
  # over an existing checkout. git refuses a non-empty target, so this failed LOUDLY rather than
  # destroying anything — fixed here because it is the same mechanism, found by the same grep.
  if git -C "$ROOT/$r" rev-parse --git-dir >/dev/null 2>&1; then
    ok "$r (present)"
  else
    git clone -q "git@github.com:tombaldwin/$r.git" "$ROOT/$r" && ok "$r (cloned)" || die "clone failed: $r"
  fi
done
if [ "$WITH_CORPORA" = 1 ]; then
  # READ-ONLY corpora. Nothing should ever write into these — copy to /tmp before scanning. They are
  # other people's repositories and one of them is the live CI consumer.
  git -C "$ROOT/pollen" rev-parse --git-dir >/dev/null 2>&1 || git clone -q git@github.com:tombaldwin/pollen.git "$ROOT/pollen" || warn "pollen clone failed (optional)"
  git -C "$ROOT/uflexi" rev-parse --git-dir >/dev/null 2>&1 || git clone -q git@bitbucket.org:polyhq/uflexi.git "$ROOT/uflexi" || warn "uflexi clone failed (needs Bitbucket auth; optional)"
  ok "corpora attempted"
fi

# ── 2. toolchains ───────────────────────────────────────────────────────────────────────────────────
say "toolchains"
brew_need() { brew list --formula "$1" >/dev/null 2>&1 || brew install "$1" >/dev/null 2>&1; }
for f in node python@3.11 gh just shellcheck; do brew_need "$f" && ok "brew $f" || warn "brew $f failed"; done
command -v java >/dev/null || { brew install --cask temurin@21 >/dev/null 2>&1 || warn "install a JDK 21 yourself"; }
ok "java: $(java -version 2>&1 | head -1)"

# NOT `--no-modify-path`. That flag was here to be polite, and its effect was that rustup installed cargo
# correctly and nothing ever put it on PATH — so the script finished green and the very next command,
# `just check`, died with `cargo: command not found`. Sourcing ~/.cargo/env below only fixes THIS shell;
# the profile line is what the next one needs. An installer that leaves the tool unusable has not
# installed it.
command -v rustup >/dev/null || curl -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v rustup >/dev/null || die "rustup install failed"
# …and belt-and-braces for a shell rustup did not know how to edit (zsh users whose PATH is set in
# .zprofile rather than .zshenv, which is exactly the case that bit us).
for prof in "$HOME/.zprofile" "$HOME/.bash_profile"; do
  [ -f "$prof" ] || continue
  grep -q 'cargo/env' "$prof" 2>/dev/null || printf '\n. "$HOME/.cargo/env"\n' >> "$prof"
done

# BOTH TOOLCHAINS NEED THE COMPONENTS, and this is the step that is easy to get wrong.
#  · candor-rust pins a NIGHTLY (rust-toolchain) because the dylint lint is rustc_private.
#  · CI lints with `+stable` SCOPED to the four engine crates — stable cannot compile the lint at all.
#  · `~/.cargo/bin/rust-analyzer` is a rustup SHIM: without the component on the ACTIVE toolchain every
#    code-intelligence request dies with `Unknown binary`, which the editor reports as a server crash.
PINNED="$(grep -m1 channel "$ROOT/candor-rust/rust-toolchain" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')"
[ -n "$PINNED" ] || die "could not read the pinned toolchain from candor-rust/rust-toolchain"
rustup toolchain install "$PINNED" -c rustc-dev -c clippy -c rust-analyzer -c llvm-tools >/dev/null 2>&1
rustup toolchain install stable -c clippy -c rust-analyzer >/dev/null 2>&1
ok "rust: stable + $PINNED (both with clippy + rust-analyzer)"

# EVERY cargo build in candor-rust needs `dylint-link`, not just the lint. `.cargo/config.toml` there sets
# `rustflags = ["-C", "linker=dylint-link"]` under `cfg(all())` — ALL targets — so without it even the
# engine crates fail, and they fail confusingly: the first errors are `could not compile proc-macro2 (build
# script)`, which reads like a broken toolchain rather than a missing linker shim. Pinned to the version
# this environment was built with, so a newer release cannot change the lint's behaviour underneath us.
DYLINT_VERSION=6.0.1
if command -v dylint-link >/dev/null; then
  ok "dylint-link (present)"
else
  say "installing the dylint linker shim (compiles from source — a few minutes)"
  cargo install --quiet --version "$DYLINT_VERSION" cargo-dylint dylint-link \
    && ok "cargo-dylint + dylint-link $DYLINT_VERSION" \
    || die "dylint-link install failed — every cargo build in candor-rust needs it (see its .cargo/config.toml)"
fi

# ── 3. build every engine ───────────────────────────────────────────────────────────────────────────
say "building the engines"
( cd "$ROOT/candor-rust"  && cargo build --release -q -p candor-scan -p candor-query ) && ok "candor-scan + candor-query" || warn "rust build failed"
( cd "$ROOT/candor-java"  && ./gradlew shadowJar -q ) && ok "candor-java jar" || warn "java build failed"
( cd "$ROOT/candor-swift" && swift build -c release >/dev/null 2>&1 ) && ok "candor-swift" || warn "swift build failed"
ok "candor-ts + candor-agents run from source"

# ── 4. the dispatcher ───────────────────────────────────────────────────────────────────────────────
say "the candor dispatcher"
LINK="$(brew --prefix)/bin/candor"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then ok "already linked: $LINK -> $(readlink "$LINK" 2>/dev/null)"
else ln -s "$ROOT/candor/bin/candor" "$LINK" && ok "linked $LINK"; fi

# ── 5. Claude Code state ────────────────────────────────────────────────────────────────────────────
say "Claude Code"
command -v claude >/dev/null || warn "claude not installed — see https://claude.com/claude-code"
cat <<'NOTE'
   These live in your HOME, not in git, so they do NOT arrive with the clones:

     claude auth login                       # authenticate on this machine
     ~/.claude/settings.json                 # copy from the old machine
     ~/.claude.json                          # MCP servers, if you have any
     claude plugins                          # reinstall what /plugins listed there

   AND THE PROJECT MEMORY, which is the one people lose:

     ~/.claude/projects/-Users-tom-git-candor/memory/

   That directory name is DERIVED FROM THE ABSOLUTE PROJECT PATH. Keep the checkout at
   /Users/tom/git/candor and it copies across verbatim and loads. Put it anywhere else and the key
   changes (e.g. -home-tom-git-candor) and the memories silently do not load — no error, they are
   simply not there. Copy it with:

     rsync -a <oldmachine>:~/.claude/projects/-Users-tom-git-candor/ \
              ~/.claude/projects/-Users-tom-git-candor/
NOTE

# ── 6. verify ───────────────────────────────────────────────────────────────────────────────────────
say "verification"
# A LOGIN SHELL, not this one. This script has already sourced ~/.cargo/env, so checking `command -v
# cargo` here would pass while the next terminal fails — which is precisely how `cargo: command not
# found` survived a green bootstrap run.
if ! ${SHELL:-/bin/zsh} -lc 'command -v cargo' >/dev/null 2>&1; then
  warn "cargo is installed but a fresh login shell cannot see it — add \`. \"\$HOME/.cargo/env\"\` to your
        shell profile, or open a new terminal and re-run"
else
  ok "cargo is on PATH in a fresh login shell"
fi
# `candor doctor` exits NON-ZERO when it finds drift — which is it working, not it failing. Piping it to
# `tail` under `set -o pipefail` and treating that as an error would report a doctor that ran and found
# real problems as "unavailable", which is the same mislabel as the ssh check above. Separate the two.
if command -v candor >/dev/null; then
  DOCTOR_OUT="$(candor doctor 2>&1)"; DOCTOR_RC=$?
  printf '%s\n' "$DOCTOR_OUT" | tail -14
  [ "$DOCTOR_RC" = 0 ] && ok "candor doctor: clean" \
    || warn "candor doctor exited $DOCTOR_RC — it found the issues above (usually: engines built here are
        older than the checkout, or declare different specs). Rebuild and re-run before trusting a
        measurement against them."
else
  warn "candor not on PATH yet — open a new shell, or check the symlink above"
fi
if [ "$RUN_CHECK" = 1 ]; then
  say "full check (slow — builds, tests, clippy, conformance, probe)"
  ( cd "$ROOT/candor" && just check )
else
  echo
  echo "   Run the real gate when you are ready (takes ~15 min):"
  echo "     cd $ROOT/candor && just check"
  echo "   A five-engine 'conformance: OK' is the signal the environment is genuinely equivalent —"
  echo "   PART 36 names any engine it could not check, so a green with a missing engine says so."
fi
