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
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q 'successfully authenticated'; then
  die "no SSH auth to github.com — add a key (ssh-keygen; gh auth login; or copy one over) and re-run"
fi
ok "github ssh auth"

# ── 1. the seven repos, as SIBLINGS ─────────────────────────────────────────────────────────────────
say "repos under $ROOT (they MUST be siblings — the tooling resolves ../../<repo>)"
mkdir -p "$ROOT"
for r in "${REPOS[@]}"; do
  if [ -d "$ROOT/$r/.git" ]; then
    ok "$r (present)"
  else
    git clone -q "git@github.com:tombaldwin/$r.git" "$ROOT/$r" && ok "$r (cloned)" || die "clone failed: $r"
  fi
done
if [ "$WITH_CORPORA" = 1 ]; then
  # READ-ONLY corpora. Nothing should ever write into these — copy to /tmp before scanning. They are
  # other people's repositories and one of them is the live CI consumer.
  [ -d "$ROOT/pollen/.git" ] || git clone -q git@github.com:tombaldwin/pollen.git "$ROOT/pollen" || warn "pollen clone failed (optional)"
  [ -d "$ROOT/uflexi/.git" ] || git clone -q git@bitbucket.org:polyhq/uflexi.git "$ROOT/uflexi" || warn "uflexi clone failed (needs Bitbucket auth; optional)"
  ok "corpora attempted"
fi

# ── 2. toolchains ───────────────────────────────────────────────────────────────────────────────────
say "toolchains"
brew_need() { brew list --formula "$1" >/dev/null 2>&1 || brew install "$1" >/dev/null 2>&1; }
for f in node python@3.11 gh just shellcheck; do brew_need "$f" && ok "brew $f" || warn "brew $f failed"; done
command -v java >/dev/null || { brew install --cask temurin@21 >/dev/null 2>&1 || warn "install a JDK 21 yourself"; }
ok "java: $(java -version 2>&1 | head -1)"

command -v rustup >/dev/null || curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path >/dev/null 2>&1
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v rustup >/dev/null || die "rustup install failed"

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
command -v candor >/dev/null && candor doctor 2>&1 | tail -12 || warn "candor doctor unavailable"
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
