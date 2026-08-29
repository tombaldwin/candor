#!/usr/bin/env python3
"""Which workflows MUST have run for this commit — asked of the workflow files, not of GitHub.

WHY THIS EXISTS (2026-08-19). ci-watch.sh printed, for the umbrella repo:

    candor  (none)  no run at HEAD (path-filtered, or never triggered — verify before trusting)

and then printed `ci-watch: OK`. The row is honest about not knowing; the verdict was not. A check
whose whole thesis is that a summary must never be greener than its rows had a fail-open in exactly
that place, and the two readings it cannot distinguish are worlds apart: "nothing in this commit
matched a path filter" is fine, and "a workflow that should have run did not" is a release blocker
wearing the same words.

Nothing about that needs GitHub to answer. The workflow files declare their own triggers, so this
reads them and the commit's changed files and says which runs are REQUIRED. ci-watch.sh then treats a
required-and-absent run as red and a not-required absence as green, with the reason printed either way.

Usage:  python3 wf-expected.py <repo-dir> [<git-rev>] [<branch>]
The branch defaults to the repo's current one; pass it when that repo is a DETACHED checkout, where
`rev-parse --abbrev-ref HEAD` says "HEAD" and every `branches:` filter would read as unmatched.

Prints one line per workflow:  <workflow FILE>\\t<required|not-required>\\t<why>
THE FIFTH FALSE GREEN (ci-watch.sh, 2026-08-29): the first column used to be the workflow's `name:` —
a display string a human chooses, which GitHub does NOT require to be unique across files. Two files in
one repo (ci-a.yml, ci-b.yml) can both declare `name: ci`, and ci-watch.sh's dedup (keyed on that same
name, now fixed on its side too) silently dropped whichever of the two `gh` listed second — including a
genuine failure. The identity emitted here is the FILE — the only thing actually unique within one
repo's .github/workflows/ directory — so a caller can tell the two apart even when their `name:` cannot.
Exit 0 always unless the repo cannot be read; an unparseable workflow is REQUIRED, because the
conservative answer to "I could not tell whether this must have run" is to make someone look.
"""
import os
import re
import subprocess
import sys


def changed_files(repo, rev):
    """Returns (files, ok). ok=False means the true file set could not be determined at all, and the
    caller must treat every workflow as required rather than read the empty list as "nothing changed".

    THE SEVENTH FALSE GREEN (2026-08-29, adversarial review): `git show --name-only --format=` returns
    an EMPTY list, exit 0 — not an error — for an ORDINARY MERGE COMMIT. `git show` prints no combined
    diff for a merge unless asked (`-m`), so a merge that genuinely touched `bin/` read as zero changed
    files and every path-filtered workflow classified NOT-REQUIRED, while GitHub's own push trigger (which
    compares the real ref delta) would have fired. Reproduced live: a backdated merge commit touching
    `bin/` returned `[]` here, exit 0; a non-merge control touching the identical file correctly returned
    the file.

    THE FIX: detect a merge (more than one parent) and diff it against its FIRST PARENT — the tip of the
    branch immediately before the merge landed — instead of asking `git show` for a combined diff it does
    not produce by default. This is the same one-rev-at-a-time scope `changed_files` already had (it has
    never modeled a multi-commit push range, merge or not); a merge's first-parent diff is what that merge
    itself changed on the branch, which is the piece GitHub's push-trigger comparison actually reduces to
    for the ordinary two-parent case this function is asked about.

    A THIRD failure mode gets the same treatment: if `rev` cannot be resolved to a commit at all (a typo,
    a repo mid-rebase, a shallow clone missing the parent), that is not "no files changed" either — it is
    "the question could not be answered", and main() below fails loudly rather than guessing "nothing
    required".
    """
    parents = subprocess.run(["git", "-C", repo, "rev-list", "--parents", "-n", "1", rev],
                             capture_output=True, text=True)
    if parents.returncode != 0 or not parents.stdout.split():
        return ([], False)
    ids = parents.stdout.split()   # ids[0] is rev itself; ids[1:] are its parents (0, 1, or more)
    if len(ids) <= 2:
        # 0 or 1 parent: the ordinary case `git show` already answers correctly (a plain commit's own
        # diff, or every file in a root commit that has no parent at all).
        out = subprocess.run(["git", "-C", repo, "show", "--name-only", "--format=", rev],
                             capture_output=True, text=True)
        if out.returncode != 0:
            return ([], False)
        return ([ln.strip() for ln in out.stdout.splitlines() if ln.strip()], True)
    # A MERGE (2+ parents): diff against the FIRST parent, never `git show`'s silent-empty default.
    out = subprocess.run(["git", "-C", repo, "diff", "--name-only", f"{ids[1]}..{rev}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return ([], False)
    return ([ln.strip() for ln in out.stdout.splitlines() if ln.strip()], True)


def glob_to_re(pat):
    """GitHub path-filter globs. `**` crosses directory separators; a lone `*` does not.

    Deliberately not fnmatch: fnmatch's `*` matches `/` as well, so `bin/*` would swallow `bin/a/b`
    and this would demand runs that GitHub never triggers — a false red in a release gate, which is
    the one failure mode that gets a check switched off.
    """
    out, i = [], 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def parse_workflow(path):
    """Returns (display_name, has_push, push_paths, tags, branches, paths_ignore, parsed_ok).

    A deliberately small reader rather than a YAML dependency: these files are machine-written and
    uniform, and the failure mode is handled — anything it cannot read is reported as REQUIRED.
    """
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return (os.path.basename(path), True, [], [], [], False)

    name = os.path.basename(path)
    has_push = False
    paths, tags, branches, paths_ignore, parsed_ok = [], [], [], [], True
    in_on = in_push = False
    listing = None   # which key's list we are currently reading items into

    for ln in lines:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        stripped = ln.strip()

        m = re.match(r'^name:\s*(.+?)\s*$', ln)
        if m and indent == 0:
            name = m.group(1).strip('"\'')
            continue

        if indent == 0:
            in_on = stripped.rstrip(":") in ("on", '"on"', "'on'") or stripped.startswith("on:")
            in_push = False
            listing = None
            continue
        if not in_on:
            continue

        if indent == 2:
            in_push = stripped.startswith("push")
            listing = None
            if in_push:
                has_push = True
                # inline form: `push:` on one line with nothing under it means every push
                continue
        if not in_push:
            continue

        # `tags:` matters as much as `paths:`. Without it candor-ts's publish.yml and candor-swift's
        # release.yml — both `on: push: tags: ['v*']` — read as "runs on every push", and the check
        # demanded a run for every branch commit. Those two are also the pair that publish on a tag
        # push, so getting their trigger wrong is not a cosmetic error.
        bucket = {"paths": paths, "tags": tags, "branches": branches,
                  "paths-ignore": paths_ignore}
        # `startswith(k)` MATCHED `paths-ignore` AS `paths`, then choked on the leftover `-ignore` and
        # set parsed_ok=False — so candor-spec's conformance.yml read as unparseable and every push to
        # that repo produced a false "NO RUN AT HEAD". Match the key EXACTLY, and check the longer key
        # first so `paths-ignore` can never be shadowed by `paths` again.
        key = next((k for k in sorted(bucket, key=len, reverse=True)
                    if indent >= 4 and stripped.startswith(k + ":")), None)
        if key:
            rest = stripped[len(key):].lstrip(":").strip()
            if rest.startswith("["):                      # key: ['a/**', 'b']
                bucket[key] += [p.strip().strip('"\'') for p in rest.strip("[]").split(",") if p.strip()]
                listing = None
            elif rest in ("", "|", ">"):                   # key:\n  - 'a/**'
                listing = key
            else:
                parsed_ok = False
            continue
        if listing:
            if stripped.startswith("- "):
                bucket[listing].append(stripped[2:].strip().strip('"\''))
            else:
                listing = None

    return (name, has_push, paths, tags, branches, paths_ignore, parsed_ok)


def classify(name, has_push, paths, tags, branches, paths_ignore, files, branch, ok, fn):
    """THE decision. main() and selftest() both call this and neither restates it.

    The first version of this file had the cascade written out in main() and written out AGAIN in the
    selftest. That selftest can only ever confirm that a copy of the logic agrees with itself — which
    is precisely how ci-watch.sh's stall alarm sat broken under a passing selftest an hour before this
    was written. One function, two callers.
    """
    if not ok:
        return ("required", f"{fn} declares triggers this reader could not parse")
    if not has_push:
        return ("not-required", f"{fn} has no push trigger")
    if tags and not branches and not paths:
        return ("not-required", f"{fn} triggers on tag pushes only ({', '.join(tags)})")
    if branches and not any(glob_to_re(b).match(branch) for b in branches):
        return ("not-required", f"{fn} runs on {', '.join(branches)}, not {branch}")
    # `paths-ignore` is the INVERSE of `paths`: GitHub skips the run only when EVERY changed file
    # matches. One unmatched file runs the workflow, which is also the safe direction for this reader —
    # a wrong answer here costs a demanded run, never a missed one.
    if paths_ignore and files and all(
            any(glob_to_re(p).match(f) for p in paths_ignore) for f in files):
        return ("not-required", f"every changed file matches {fn}'s paths-ignore")
    if not paths:
        return ("required", f"{fn} runs on every push (no path filter)")
    hits = [f for f in files for p in paths if glob_to_re(p).match(f)]
    if hits:
        return ("required", f"this commit touches {hits[0]}")
    return ("not-required", "no changed file matches its path filter")


SELFTEST_CASES = [
    # (yaml, changed files, branch, expected verdict, what it is)
    # THE FALSE RED THIS READER ACTUALLY PRODUCED. `paths-ignore` starts with `paths`, so a
    # `startswith(key)` match read it as a malformed `paths:` and declared the whole workflow
    # unparseable — which fails CLOSED to "required", so candor-spec reported NO RUN AT HEAD on every
    # push after that key was added.
    ("name: conf\non:\n  push:\n    branches: [main]\n    paths-ignore:\n      - 'CHANGELOG.md'\n",
     ["CHANGELOG.md"], "main", "not-required",
     "paths-ignore, and every changed file matches it"),
    ("name: conf\non:\n  push:\n    branches: [main]\n    paths-ignore:\n      - 'CHANGELOG.md'\n",
     ["CHANGELOG.md", "SPEC.md"], "main", "required",
     "paths-ignore, but ONE changed file is not ignored — GitHub runs it, so this must too"),
    ("name: conf\non:\n  push:\n    branches: [main]\n    paths-ignore: ['CHANGELOG.md']\n",
     ["CHANGELOG.md"], "main", "not-required",
     "…and the same in the inline list form"),
    ("name: ci\non:\n  push:\n", ["README.md"], "main", "required",
     "no filter at all — every push"),
    # The two that produced this reader's first FALSE REDS. Both publish artifacts on a tag push, so
    # reading them as `runs on every push` demanded a run for every branch commit and would have held a
    # release on a workflow that was never going to exist.
    ("name: publish\non:\n  push:\n    tags: ['v*']\n  workflow_dispatch:\n", ["a.ts"], "main",
     "not-required", "tag-only trigger, inline list"),
    ("name: release\non:\n  push:\n    tags:\n      - 'v*'\n", ["a.swift"], "main",
     "not-required", "tag-only trigger, block list"),
    ("name: shell-lint\non:\n  push:\n    paths: ['bin/**', 'justfile']\n", ["bin/x.sh"], "main",
     "required", "path filter hit"),
    ("name: shell-lint\non:\n  push:\n    paths: ['bin/**', 'justfile']\n", ["CHANGELOG.md"], "main",
     "not-required", "path filter missed — the case that used to print OK on an unknown"),
    ("name: vscode\non:\n  push:\n    paths:\n      - 'integrations/vscode/**'\n", ["integrations/vscode/a/b.ts"],
     "main", "required", "** crosses directories"),
    ("name: narrow\non:\n  push:\n    paths: ['bin/*']\n", ["bin/a/b.sh"], "main", "not-required",
     "a lone * does NOT cross a directory separator — fnmatch would get this wrong"),
    ("name: main-only\non:\n  push:\n    branches: ['main']\n", ["a.rs"], "feature/x", "not-required",
     "branch filter excludes this branch"),
    ("name: main-only\non:\n  push:\n    branches: ['main']\n", ["a.rs"], "main", "required",
     "branch filter includes this branch"),
    ("name: cron\non:\n  schedule:\n    - cron: '0 3 * * *'\n", ["a.rs"], "main", "not-required",
     "no push trigger"),
    ("name: weird\non:\n  push:\n    paths: &anchor\n", ["a.rs"], "main", "required",
     "UNPARSEABLE must fail closed — the answer to 'I could not tell' is to make someone look"),
]


def selftest():
    import tempfile
    fails = 0
    for yaml_text, files, branch, want, why in SELFTEST_CASES:
        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as fh:
            fh.write(yaml_text)
            path = fh.name
        name, has_push, paths, tags, branches, pignore, ok = parse_workflow(path)
        os.unlink(path)
        got, _why = classify(name, has_push, paths, tags, branches, pignore, files, branch, ok,
                             os.path.basename(path))
        mark = "\u2714" if got == want else "\u2718"
        if got != want:
            fails += 1
        print(f"  {mark} {got:<13} (want {want:<13}) {why}")
    print("wf-expected selftest: " + ("OK \u2014 every trigger shape classifies as declared"
                                      if not fails else f"FAILED \u2014 {fails} case(s)"))
    return fails


def selftest_duplicate_names():
    """THE FIFTH FALSE GREEN, exercised through the REAL subprocess against a REAL throwaway repo \u2014 not
    a copy of classify()'s logic, the same discipline this file's own docstring credits for catching the
    ORIGINAL bug (a selftest that only ever agreed with a second copy of itself). Two workflow files both
    declare `name: ci`; main()'s output must key each on its FILE, not the name they share.
    """
    import subprocess
    import tempfile
    import shutil

    d = tempfile.mkdtemp()
    fails = 0
    try:
        wfdir = os.path.join(d, ".github", "workflows")
        os.makedirs(wfdir)
        with open(os.path.join(wfdir, "ci-a.yml"), "w", encoding="utf-8") as fh:
            fh.write("name: ci\non:\n  push:\n    branches: [main]\n")
        with open(os.path.join(wfdir, "ci-b.yml"), "w", encoding="utf-8") as fh:
            fh.write("name: ci\non:\n  push:\n    branches: [main]\n")
        run = lambda *a: subprocess.run(["git", "-C", d, *a], capture_output=True, text=True)
        run("init", "-q", "-b", "main")
        run("-c", "user.email=t@t", "-c", "user.name=t", "add", "-A")
        run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
        out = subprocess.run([sys.executable, os.path.abspath(__file__), d, "HEAD", "main"],
                             capture_output=True, text=True).stdout
        rows = [ln.split("\t") for ln in out.splitlines() if ln.strip()]
        keys = sorted(r[0] for r in rows)
        ok = (keys == ["ci-a.yml", "ci-b.yml"] and len(rows) == 2
              and all(r[1] == "required" for r in rows))
        mark = "\u2714" if ok else "\u2718"
        print(f"  {mark} duplicate name 'ci' across ci-a.yml/ci-b.yml -> keys {keys!r} "
              "(want two DISTINCT file keys, never one collapsed 'ci')")
        if not ok:
            fails += 1
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return fails


def selftest_merge_commit():
    """THE SEVENTH FALSE GREEN, exercised through the REAL subprocess against a REAL merge commit — same
    discipline as selftest_duplicate_names() above, not a copy of changed_files()'s logic. `git show
    --name-only --format=` prints nothing for an ordinary merge; before the fix that read as "no changed
    files" and every path-filtered workflow classified NOT-REQUIRED.

    Three cases: a merge that DOES touch the filtered path (must read REQUIRED — this is the bug), a merge
    that does NOT (must still read NOT-REQUIRED — the fix must not simply mark every merge required
    unconditionally, which would be a different false alarm), and a rev this reader cannot resolve at all
    (must fail loudly, exit 2, rather than silently answer "nothing required").
    """
    import subprocess
    import tempfile
    import shutil

    d = tempfile.mkdtemp()
    fails = 0
    try:
        wfdir = os.path.join(d, ".github", "workflows")
        os.makedirs(wfdir)
        with open(os.path.join(wfdir, "shell-lint.yml"), "w", encoding="utf-8") as fh:
            fh.write("name: shell-lint\non:\n  push:\n    branches: [main]\n    paths: ['bin/**']\n")
        run = lambda *a: subprocess.run(["git", "-C", d, *a], capture_output=True, text=True)
        genv = ["-c", "user.email=t@t", "-c", "user.name=t"]
        run("init", "-q", "-b", "main")
        os.makedirs(os.path.join(d, "bin"))
        with open(os.path.join(d, "README.md"), "w", encoding="utf-8") as fh:
            fh.write("base\n")
        run(*genv, "add", "-A")
        run(*genv, "commit", "-qm", "base")

        def merge_touching(rel_path, content):
            run("checkout", "-q", "-b", "feature")
            with open(os.path.join(d, rel_path), "w", encoding="utf-8") as fh:
                fh.write(content)
            run(*genv, "add", "-A")
            run(*genv, "commit", "-qm", f"feature: touch {rel_path}")
            run("checkout", "-q", "main")
            with open(os.path.join(d, "README.md"), "a", encoding="utf-8") as fh:
                fh.write("main-side change\n")
            run(*genv, "add", "-A")
            run(*genv, "commit", "-qm", "main: unrelated")
            run(*genv, "merge", "-q", "--no-ff", "-m", "merge feature", "feature")
            sha = run("rev-parse", "HEAD").stdout.strip()
            run("branch", "-q", "-D", "feature")
            return sha

        merge_in_scope = merge_touching("bin/x.sh", "feature change\n")
        out = subprocess.run([sys.executable, os.path.abspath(__file__), d, merge_in_scope, "main"],
                             capture_output=True, text=True)
        rows_in = dict(ln.split("\t")[:2] for ln in out.stdout.splitlines() if ln.strip())
        ok_in = rows_in.get("shell-lint.yml") == "required"
        print(f"  {'✔' if ok_in else '✘'} merge commit TOUCHING bin/ -> {rows_in.get('shell-lint.yml')} "
              "(want required — the bug reported 'not-required', GitHub would have run it)")
        if not ok_in:
            fails += 1

        merge_out_of_scope = merge_touching("docs.md", "prose\n")
        out2 = subprocess.run([sys.executable, os.path.abspath(__file__), d, merge_out_of_scope, "main"],
                              capture_output=True, text=True)
        rows_out = dict(ln.split("\t")[:2] for ln in out2.stdout.splitlines() if ln.strip())
        ok_out = rows_out.get("shell-lint.yml") == "not-required"
        print(f"  {'✔' if ok_out else '✘'} merge commit NOT touching bin/ -> {rows_out.get('shell-lint.yml')} "
              "(want not-required — the fix must not mark every merge required unconditionally)")
        if not ok_out:
            fails += 1

        out3 = subprocess.run([sys.executable, os.path.abspath(__file__), d, "not-a-real-rev", "main"],
                              capture_output=True, text=True)
        ok3 = out3.returncode == 2 and not out3.stdout.strip() and "could not determine" in out3.stderr
        print(f"  {'✔' if ok3 else '✘'} unresolvable rev -> exit {out3.returncode}, stdout={out3.stdout!r} "
              "(want exit 2, empty stdout, a named stderr reason — never a silent 'nothing required')")
        if not ok3:
            fails += 1
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return fails


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        f1 = selftest()
        print()
        f2 = selftest_duplicate_names()
        print()
        f3 = selftest_merge_commit()
        total = f1 + f2 + f3
        print("wf-expected selftest (combined): " + ("OK" if total == 0 else f"FAILED — {total} case(s)"))
        return total
    repo = sys.argv[1]
    rev = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
    wfdir = os.path.join(repo, ".github", "workflows")
    if not os.path.isdir(wfdir):
        return 0
    files, files_ok = changed_files(repo, rev)
    if not files_ok:
        # THE SEVENTH FALSE GREEN's other half: an undetermined file set must never fall through as an
        # empty one. An empty `files` here reads, in classify(), as "no changed file matches any path
        # filter" — the identical shape to a genuinely quiet commit — so this fails the whole call loudly
        # instead, the same convention the detached-HEAD-with-no-branch-argument case below already uses.
        sys.stderr.write(f"wf-expected: could not determine the changed-file set for {rev!r} in {repo!r} "
                         "(unresolvable rev, or its parent is missing) — refusing to guess 'nothing "
                         "required'. Verify by hand.\n")
        return 2
    # THE BRANCH CAN BE PASSED IN, and it has to be. `rev-parse --abbrev-ref HEAD` answers the literal
    # string "HEAD" in a DETACHED checkout — which is neither empty (so the `or "main"` fallback below
    # never fires) nor any branch a `branches:` filter names, so every branch-filtered workflow read as
    # NOT REQUIRED. `verify-umbrella.sh` validates commits in exactly such a worktree, and on its first
    # green control that silently dropped `integrations`, `release-scripts` and `vscode` from a push
    # that touches all three. A skip that looks like a pass is the failure this whole family of checks
    # exists to prevent, so the caller that knows the answer says it.
    branch = sys.argv[3] if len(sys.argv) > 3 else ""
    if not branch:
        branch = subprocess.run(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"],
                                capture_output=True, text=True).stdout.strip() or "main"
    if branch == "HEAD":
        sys.stderr.write("wf-expected: detached HEAD and no branch argument — every `branches:` filter "
                         "would read as unmatched. Pass the target branch as argv[3].\n")
        return 2

    for fn in sorted(os.listdir(wfdir)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        name, has_push, paths, tags, branches, pignore, ok = parse_workflow(os.path.join(wfdir, fn))
        verdict, why = classify(name, has_push, paths, tags, branches, pignore, files, branch, ok, fn)
        # THE IDENTITY COLUMN IS THE FILE, NOT `name` — see the fifth-false-green note in this file's
        # docstring. `name` (the human `name:` display string) is still fed into classify() above only
        # because some of its `why` messages read better with it; it is never the key a caller matches on.
        print(f"{fn}\t{verdict}\t{why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
