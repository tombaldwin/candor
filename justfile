# candor — family task runner. `just` (https://github.com/casey/just), `brew install just`.
#
# WHY: every recipe here is a command that was got WRONG by hand during the 0.27 release. The rust
# build is the sharpest example — `cargo build --release` at that repo's root builds the dylint LINT,
# not the engines, so a release binary silently aged eight days and a reviewer measuring it reported one
# defect that was already fixed and one that never existed.

root := justfile_directory() / ".."

default:
    @just --list

# Build every engine. NOT `cargo build --release` at the rust root — see the note above.
build:
    cd {{root}}/candor-rust && cargo build --release -p candor-scan -p candor-query
    cd {{root}}/candor-java && ./gradlew shadowJar -q
    cd {{root}}/candor-swift && swift build -c release
    @echo "ts and agents run from source — nothing to build"

# Every engine's own suite.
test:
    cd {{root}}/candor-swift && swift test
    cd {{root}}/candor-rust && cargo test -q
    cd {{root}}/candor-agents && python3 test.py
    cd {{root}}/candor && bash bin/release-test.sh

# The POLICY-PARSER properties (candor-classify, proptest). Seconds, and the one surface the family's
# generative fuzzers miss: they all generate CODE and check effect propagation, none generates a POLICY —
# which is where the fail-open defects have actually lived. Shrinking is the point: a failure names the
# minimal offending line, not the 40-line policy that contained it.
props:
    cd {{root}}/candor-rust && cargo test -p candor-classify policy_props

# The four-way differential. Run it after ANY classifier change — never one generator.
conformance:
    cd {{root}}/candor-spec && bash conformance/run.sh

# One part of the differential, for iterating (PART 31 in 6s rather than the suite's 476s). A FILTERED
# run is not a conformance result and says so on every run. `just conformance-parts` lists the ids.
conformance-part +ids:
    cd {{root}}/candor-spec && bash conformance/part.sh {{ids}}

conformance-parts:
    cd {{root}}/candor-spec && bash conformance/part.sh --list

# Do part.sh's boundary rules still fit run.sh? ~10s, runs no engine. Run it after editing run.sh.
conformance-parts-check:
    cd {{root}}/candor-spec && bash conformance/part.sh --check

# The exit-2 cause matrix: every cause a user can trigger, both sink forms, all four engines.
probe *engines:
    cd {{root}}/candor && bash bin/probe-causes.sh {{engines}}

# CLIPPY EXACTLY AS CI RUNS IT — `+stable`, which is the whole point. candor-rust pins a NIGHTLY
# (rust-toolchain, for the dylint lint), so a bare `cargo clippy` here runs nightly's lint set while CI
# runs stable's. The first version of this recipe omitted `+stable` and passed clean while CI failed on
# `collapsible_if` — a local check that reproduces a different check is worse than none, because it is
# believed. It is also SCOPED with -p exactly as CI is: stable clippy cannot compile the rustc_private
# dylint lib at the repo root, so an unscoped `cargo +stable clippy` here dies on `can't find crate for
# rustc_driver` before it lints a single engine crate. The second line is CI's other leg — the pinned
# nightly over the whole workspace, which covers the lint lib and build.rs that stable cannot see. `cargo build` and `cargo test` both pass on lints that `-D warnings`
# rejects, so this class only ever failed in CI — measured: a doc comment separated from its item by a
# blank line (`empty_line_after_doc_comments`) built and tested clean locally and broke the rust CI run.
clippy:
    cd {{root}}/candor-rust && cargo +stable clippy -p candor-report -p candor-query -p candor-classify -p candor-scan --all-targets -- -D warnings
    cd {{root}}/candor-rust && cargo clippy --workspace --all-targets -- -D warnings

# Lint the release machinery. Backticks inside a double-quoted shell string are live command
# substitution — that silently deleted three filenames from the one message an operator is guaranteed
# to read, and `bash -n` cannot see it because it is valid syntax.
lint:
    shellcheck -S warning {{root}}/candor/bin/*.sh {{root}}/candor-spec/conformance/run.sh {{root}}/candor-spec/conformance/part.sh

# Everything a change should pass before it is pushed.
check: build test props clippy conformance probe

# Reproduce this development environment on a fresh macOS machine (seven sibling repos, five toolchains,
# two rust toolchains with components, the dispatcher symlink). Re-runnable.
bootstrap *flags:
    bash {{root}}/candor/bin/bootstrap-dev.sh {{flags}}

# What CI runs, before pushing. Two halves, because the family has two: `verify-local.sh` runs each
# ENGINE repo's own gate, and this runs the UMBRELLA's — derived from .github/workflows/*.yml rather than
# transcribed, so it cannot drift the way a hand-kept list did (a four-command "union of what the three
# workflows run" was missing four of integrations.yml's nine steps, and main went red on the push).
# `just verify-umbrella --docker` runs the ubuntu jobs on linux/amd64: on 0382c91^ the dispatcher routing
# contract passes on darwin/arm64 and fails on linux exactly as CI did.
verify-umbrella *flags:
    cd {{root}}/candor && bash bin/verify-umbrella.sh {{flags}}

verify-engines *repo:
    cd {{root}}/candor && bash bin/verify-local.sh {{repo}}

# THE DRESS REHEARSAL — everything the release ladder does except publishing, every failure at once.
# The 0.32.0 cut found them one per ~10-minute CI round: rust red, then swift, then spec, then three
# rounds of preflight. `just rehearse 0.32 0.32.2`.
rehearse spec version *flags:
    cd {{root}}/candor && bash bin/release-rehearsal.sh {{spec}} {{version}} {{flags}}

# Release gates (read-only — publishing is deliberately NOT a recipe).
# `*flags` carries `--only <repos>` through for a SCOPED cut (one engine at a patch version, the rest of
# the family unmoved): `just preflight 0.32 0.32.1 --only candor-java`. With no flag both behave exactly
# as before and judge the whole family.
preflight spec version *flags:
    cd {{root}}/candor && bash bin/release-preflight.sh {{spec}} {{version}} {{flags}}

verify spec version *flags:
    cd {{root}}/candor && bash bin/release-verify.sh {{spec}} {{version}} {{flags}}
