#!/usr/bin/env bash
# _release_notes.sh — SELECT THE RELEASE NOTES FOR ONE REPO, OR REFUSE. Nothing else.
#
#   bash bin/_release_notes.sh <repo> <spec> <version> <path/to/CHANGELOG.md>
#
#   stdout : the notes `release.sh` would publish (heading line first), capped at 120000 bytes, cut at an entry
#            boundary, with a trailer naming every omitted entry appended only when the cap cut something)
#   exit 0 : a section belonging to THIS version was found
#   exit 3 : REFUSED — the reason, with its remedy, is on stderr and NOTHING is on stdout
#
# ── WHY THIS IS ITS OWN FILE, AND WHY IT REFUSES ─────────────────────────────────────────────────────
#
# This logic lived inline in `release.sh`'s `rel()` and ended in a silent FALL-THROUGH: if the version
# had no section, it published "the newest non-empty section" — i.e. THE PREVIOUS VERSION'S NOTES, under
# the new tag, with a yellow `•` nobody reads at the end of a release. The state that reaches it is not
# exotic; it is the ordinary one. `_stage_changelogs.py` deliberately SKIPS an EMPTY `## Unreleased`
# (nothing should ship unlabelled), so a repo with nothing to say gets no `## [VERSION]` heading, and a
# repo with nothing to say is exactly what a family BUILD BUMP is.
#
# MEASURED THREE TIMES. candor-swift's and candor-agents' `## [0.29.1]` entries read, verbatim,
# "**Family build bump only — no engine changes in this repo**", and say in the entry itself that they
# were hand-written only because an empty section would otherwise republish the previous notes. On
# 2026-08-25 candor-agents hit it again before the 0.32.0 cut — caught by a reviewer READING the script —
# and after that cut all seven repos sat with an empty `## Unreleased`, so a family-wide 0.32.1 would
# have published 0.32.0's notes under v0.32.1 in six of them.
#
# THE ASYMMETRY DECIDES IT. Publishing the wrong notes is SILENT and reaches users, permanently, on a
# GitHub release nobody re-reads. Refusing to publish is LOUD and reaches one operator, mid-run, with a
# one-command remedy — and `release.sh` step 1-3 skip what already exists, so a refusal costs a re-run,
# not a release. So there is no fall-through here: a version whose notes cannot be identified is not
# published at all.
#
# ── THE ONE POSITIONAL SELECTION THAT SURVIVES, AND ITS FENCE ────────────────────────────────────────
#
# The umbrella's CHANGELOG is DATED, not versioned, and says so in its own header ("not a versioned
# release artifact"). It has no `## [X.Y.Z]` heading and never should, so its notes genuinely ARE its
# newest section. That arm is kept — fenced to the repo it was written for, and fenced again by a
# POSITIVE assertion: the selected heading must carry `_stage_changelogs.py`'s `(released … as $VER)`
# stamp. Without that second fence the umbrella keeps the whole defect: a run with no `(unreleased)`
# heading to stamp selects the PREVIOUS date's section and publishes it under the new tag.
#
# Naming one repo is an ALLOWLIST, and this project's standing rule is that an allowlist under-reports
# what you forgot. It is the right shape HERE because of which way its omissions fail: a repo missing
# from it cannot use positional selection, so it REFUSES — loud, operator-only, one re-run. An eighth
# family repo with a dated changelog costs one line in this file; the denylist spelling ("everything
# except the five engines may guess") would hand positional selection to a repo nobody considered.
set -uo pipefail

REPO="${1:?usage: _release_notes.sh <repo> <spec> <version> <changelog-path>}"
SPEC="${2:?usage: _release_notes.sh <repo> <spec> <version> <changelog-path>}"
VER="${3:?usage: _release_notes.sh <repo> <spec> <version> <changelog-path>}"
CL="${4:?usage: _release_notes.sh <repo> <spec> <version> <changelog-path>}"

# `refuse` writes to STDERR and stdout stays EMPTY, so a caller that ignores the exit code publishes
# nothing rather than publishing a diagnostic. (`release.sh` checks the code; the next caller might not.)
refuse() { printf '%s\n' "$*" >&2; exit 3; }

[ -f "$CL" ] || refuse "$REPO: no CHANGELOG.md at $CL — refusing to publish a release with no notes."

# GitHub caps a release body at 125000 characters and candor-swift's CHANGELOG is 154KB, so `-F
# CHANGELOG.md` 422'd mid-release on 0.25 and left that repo TAGGED WITH NO RELEASE — the state that
# broke `candor update` at 0.24. A LINE cap (`head -80`) was the first fix and was itself a defect:
# every engine's ⟨0.35⟩ section ran past 80 lines (rust 269, java 304, ts 758, swift 360) and every one
# got cut mid-sentence BEFORE its published-sin entries, silently. A BYTE cap under the real limit is
# the actual constraint; `CAP` below leaves headroom under 125000 for the trailer `cap_body` appends,
# and appends it ONLY when the cap actually cut something, so a section that fits (every one measured
# for ⟨0.35⟩, including ts's ~64KB) is published byte-for-byte with no pointless trailer.
CAP=120000
# CUT AT AN ENTRY BOUNDARY, AND NAME WHAT WAS CUT. Measured 2026-09-29 on candor-rust's ⟨0.39.3⟩ section
# (131,698 bytes): the old `head -c` dropped six entries, FOUR of them ⚠ gate-changing (one mid-entry),
# from the release page with only "Full notes: CHANGELOG.md" to say so — while that repo's own preamble
# tells users to read every ⚠ entry before bumping a pin. The cap is GitHub's (125000 characters; this
# measures BYTES, which are never fewer), so it cannot be raised; what can change is that nothing leaves
# silently.
#
# An entry boundary is a column-0 line starting `- `, `* ` or a `##`–`####` heading, OUTSIDE a ``` fence
# (a bullet inside a code block is not an entry, and a cut there would leave the fence open). Every
# omitted segment is named — a heading by its text, prefixed `§`, so prose under it is not dropped
# unnamed — and a segment is ⚠ if its TEXT carries ⚠, not only its title. The trailer degrades in steps
# until one fits: full titles → titles shortened to 80 chars → the ⚠ ones only, plus a count of the rest →
# a count alone. Each step keeps the LARGEST body that fits with it; an entry larger than half the page is
# cut at a line inside it and still listed. First review of this code (release
# panel, 2026-09-30) found the first cut had no step between "all names" and "no names", excluded heading
# segments, and cut inside fences; release-test pins all three.
cap_body() {
  local size
  size="$(wc -c < "$OUT")"
  [ "$size" -gt "$CAP" ] || return 0
  CAP="$CAP" python3 - "$OUT" <<'PY'
import os, re, sys
path, cap = sys.argv[1], int(os.environ["CAP"])
data = open(path, "rb").read()
starts, lines, off, fence = [], [], 0, False  # entry boundaries; every line start outside a fence
for i, ln in enumerate(data.splitlines(keepends=True)):
    if ln.lstrip().startswith(b"```"):
        fence = not fence
    elif i > 0 and not fence:
        lines.append(off)
        if re.match(rb"(- |\* |#{2,4} )", ln):
            starts.append(off)
    off += len(ln)
starts.append(len(data))
WARN = "⚠"
def title(chunk, width):
    text = chunk.decode("utf-8", "replace")
    if text.startswith("#"):
        t = "§ " + " ".join(text.split("\n", 1)[0].lstrip("#").split())
    else:
        m = re.match(r"[-*]\s*(?:\u26a0\s*)?\*\*(.+?)\*\*", text, re.S)  # `- ⚠ **…**` as well as `- **⚠ …**`  # the entry's bold lead, across wrapped lines
        t = " ".join((m.group(1) if m else text.split("\n", 1)[0]).split())
        t = re.sub(r"^[-*]\s*", "", t).replace("**", "")
    if WARN in text and WARN not in t:
        t = WARN + " " + t
    return t if len(t) <= width else t[:width - 3].rstrip() + "..."
def omitted(cut):
    # A cut inside an entry (the mid-entry step below) names that entry too — it is only partly shown.
    return [data[a:b] for a, b in zip(starts, starts[1:]) if b > cut]
def trailer(cut, level):
    segs = omitted(cut)
    warn = [s for s in segs if WARN.encode() in s]
    rest = [s for s in segs if WARN.encode() not in s]
    n, k = len(segs), len(warn)
    head = (f"\n\n---\nThese notes exceed GitHub's release-body limit. {n} further entr{'y' if n == 1 else 'ies'}"
            f" ({k} ⚠) {'is' if n == 1 else 'are'} in CHANGELOG.md in the repository, not shown here")
    if level == 3:
        return head + ".\n"
    width = 200 if level == 0 else 80
    named = warn + rest if level < 2 else warn
    body = "".join(f"- {title(s, width)}\n" for s in named)
    if level == 2 and rest:
        body += f"- …and {len(rest)} other entr{'y' if len(rest) == 1 else 'ies'} without ⚠\n"
    return head + ":\n\n" + body
result = None
for level in range(4):
    for c in reversed(starts[:-1]):
        t = trailer(c, level)
        if c + len(t.encode()) <= cap:
            result = (c, t); break
    if result:
        break
# ONE ENTRY LARGER THAN THE PAGE. When the best clean cut keeps under half the cap (a single huge entry, or
# a huge fenced block), cut at a LINE outside a fence inside it instead; `omitted` then names that entry as
# well, so it is shown in part AND listed.
if result is None or result[0] < cap // 2:
    for level in range(4):
        mid = next(((c, trailer(c, level)) for c in reversed(lines)
                    if c + len(trailer(c, level).encode()) <= cap), None)
        if mid:
            if result is None or mid[0] > result[0]:
                result = mid
            break
# LAST RESORT: a byte cut, used only when nothing above keeps half the page (no boundary fits, or one
# unbroken line longer than the page). Never inside a UTF-8 sequence; closes a fence it lands in; still
# names the entry it cuts through and everything after it.
if result is None or result[0] < cap // 2:
    for level in range(4):
        c = cap - len(trailer(cap, level).encode()) - 16
        while c > 0 and (data[c] & 0xC0) == 0x80:
            c -= 1
        t = trailer(c, level)
        if sum(1 for ln in data[:c].splitlines() if ln.lstrip().startswith(b"```")) % 2 == 1:
            t = "\n```" + t
        if c > 0 and c + len(t.encode()) <= cap:
            if result is None or c > result[0]:
                result = (c, t)
            break
if result is None:  # nothing fits even as a count: publish the count alone
    result = (0, trailer(0, 3))
c, t = result
open(path, "wb").write(data[:c].rstrip(b"\n") + t.encode())
PY
}
sect_by_version() { awk -v v="## [$VER]" 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$CL"; }
# candor-spec's older headings are FLOOR-shaped (`## 0.27 — …`) rather than `## [0.27.0]`, which the
# version anchor cannot see. No engine changelog writes that shape, so trying it everywhere is inert.
sect_by_floor()   { awk -v v="## $SPEC "  'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$CL"; }
# The newest section that is not a `## Unreleased` placeholder. `\[?…\]?`: the bracketed
# `## [Unreleased]` is the other spelling this family writes, and the first version of this skip matched
# only the bare one — an empty bracketed heading published as a one-line body.
sect_newest()     { awk '/^## \[?[Uu]nreleased\]?/{skip=1;next} /^## /{if(skip){skip=0;n++} else n++} n==1&&!skip{print} n==2{exit}' "$CL"; }

# A FILE, NOT A `$(…)` ROUND TRIP. Command substitution strips trailing newlines, so routing the section
# through a variable silently drops the blank line every one of these sections ends with — a one-byte
# change to what gets published, introduced by the fix that exists to stop the notes changing. Measured
# on all seven repos while proving this file publishes what the inline awk published.
OUT="$(mktemp "${TMPDIR:-/tmp}/rel-notes.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

# TWO DIFFERENT QUESTIONS, AND CONFLATING THEM IS ITS OWN BUG. `-s` asks whether a heading MATCHED —
# these awk programs print the heading line first, so a section with an empty body is a non-empty file.
# `has_body` asks whether anything was WRITTEN under it. The fall from the version anchor to the floor
# anchor keys on the FIRST (as it always has): a bodyless `## [0.32.1]` in candor-spec must not slide
# down onto the `## 0.32` floor section and publish the floor's notes under a patch tag — that is the
# same wrong-notes defect this file exists for, arriving through the fallback that replaced it.
has_body() { [ "$(sed -n '2,$p' "$OUT" | grep -c '[^[:space:]]')" -gt 0 ]; }

sect_by_version > "$OUT"
[ -s "$OUT" ] || sect_by_floor > "$OUT"
if [ -s "$OUT" ]; then
  has_body || refuse "$REPO: \`$(head -1 "$OUT")\` is a heading with NO BODY — REFUSING to publish.
     GitHub would take it verbatim, so the release notes for v$VER would read, in full, as that one line.
     Remedy: write the entry. \`bash bin/release-stage.sh $VER --only $REPO\` generates a build-bump stub
     if this repo genuinely has nothing to say; otherwise say what changed."
  cap_body
  cat "$OUT"
  exit 0
fi

if [ "$REPO" != "candor" ]; then
  refuse "$REPO: CHANGELOG.md has no \`## [$VER]\` section (and no \`## $SPEC\` floor section) — REFUSING to publish.
     There IS a newest section in that file and it belongs to a PREVIOUS release; publishing it under
     v$VER is the silent defect this refusal exists to stop. This is what an EMPTY \`## Unreleased\`
     leaves behind, which is the ordinary state of a repo that has nothing to say in a build bump.
     Remedy: \`bash bin/release-stage.sh $VER --only $REPO\` — it turns an empty \`## Unreleased\` into a
     stubbed \`## [$VER]\` entry, which you then rewrite in this repo's own voice. Commit, push, re-run
     release.sh: steps 1-3 skip everything already published."
fi

# ── THE UMBRELLA ARM: dated, so positional — but the stamp must say THIS version ────────────────────
sect_newest > "$OUT"
[ -s "$OUT" ] || refuse "candor: CHANGELOG.md yields no section at all — refusing to publish an empty release."
has_body || refuse "candor: the umbrella's newest section \`$(head -1 "$OUT")\` has NO BODY — refusing to publish
     a release whose notes would read as that one line."
head_line="$(head -1 "$OUT")"
case "$head_line" in
  "## "*"(released "*" as $VER)"*) ;;
  *) refuse "candor: the umbrella's newest section is \`$head_line\` — it carries no \`(released … as $VER)\`
     stamp, so it belongs to a PREVIOUS release and publishing it under v$VER would republish old notes.
     The umbrella's changelog is DATED, not versioned, so its notes are its newest section and the stamp
     is the only thing that ties a section to a version.
     Remedy: \`bash bin/release-stage.sh $VER\` — it stamps every \`(unreleased)\` dated heading, and opens
     a stubbed dated section when there is none. Commit, push, re-run release.sh." ;;
esac
cap_body
cat "$OUT"
exit 0
