#!/usr/bin/env python3
"""Enumerate the STEPS of this repo's workflows, and say which of them can honestly run here.

WHY THIS EXISTS (2026-08-25). `bin/verify-local.sh` walks the ENGINE repos; nothing ran the UMBRELLA's
own workflows. So an agent ran `release-test.sh`, `candor.test.sh`, `shellcheck` and `bash -n` in a clean
worktree and called that "the union of what the three workflows run". It was not — `integrations.yml`
runs nine steps and that list has five of them, missing (among others) the dispatcher routing contract.
main went red on the push.

The lesson is not "that list was wrong". It is that a HAND-KEPT list of what CI runs drifts from CI by
construction, silently, in the direction of running less. So nothing here is transcribed: the workflow
files are the input, every `run:` step in them is enumerated, and a step this machine cannot honestly
run is REPORTED AS NOT RUN with the reason — never dropped. Add a step to a workflow and it appears
here on the next invocation with no edit to this file.

    python3 bin/wf-steps.py <repo-dir> [--event push] [--os linux|darwin]

One 0x1f-separated record per step, on stdout (0x1f and not TAB — see SEP below):

    status ␟ file ␟ workflow ␟ job ␟ runs-on ␟ label ␟ reason ␟ workdir ␟ shell ␟ env_b64 ␟ script_b64

  RUN        a `run:` script with nothing standing in the way — execute it. `reason` is EMPTY, or an
             ADVISORY: the step runs, but under a condition CI would not have given it (the usual one
             being a job declaring `runs-on: ubuntu-*` executed on a macOS host).
  SKIP       it exists and is NOT being run; `reason` says why, and the caller MUST print it
  PROVISION  a `uses:` step — the GitHub runner's environment setup, which has no local execution.
             `reason` names the tool it provisions so the caller can assert that tool is present.

A PLATFORM MISMATCH IS AN ADVISORY, NOT A SKIP — a decision, and this is the reasoning. Every job in
this repo declares `runs-on: ubuntu-latest`, so making the mismatch disqualifying would skip 100% of
the steps on the macOS machine they are written on, and a gate that runs nothing is a gate nobody runs.
Running them and SAYING SO on the row keeps the finding and the caveat together, and `--docker` removes
the caveat outright. `runs-on: windows-*` IS a skip: there is nothing to approximate with.

`status` is never omitted and never guessed: a step this reader cannot classify is SKIP with the reason
"unclassifiable", because a silent drop is the exact failure this file exists to prevent.

WHAT IT DOES NOT DECIDE. Whether GitHub would TRIGGER a given workflow for a given commit is
`bin/wf-expected.py`'s question and is answered there — one owner per question, because that file's own
header records a selftest that could only ever confirm a copy of the logic agreed with itself. This
reader reports every workflow's steps and lets the caller filter.
"""
import base64
import os
import re
import sys

try:
    import yaml
except ImportError:                                              # pragma: no cover - environment
    sys.stderr.write(
        "wf-steps: PyYAML is required and is absent.\n"
        "  This reader refuses to fall back to a line-scanner: a partial enumeration of what CI runs is\n"
        "  the failure it exists to prevent, and it would look exactly like a complete one.\n"
        "  Remedy: python3 -m pip install --user pyyaml\n")
    sys.exit(2)

# `uses:` steps are the runner's environment, and they have no local execution — but most of them stand
# for a TOOL, and the caller can check that tool is present. The map is deliberately small and its
# unknown case is safe: an action that is not here is reported as provisioning with no tool asserted,
# which is a weaker claim, not a wrong one. It can never cause a step to be silently skipped.
PROVISION_TOOL = {
    "actions/setup-python": "python3",
    "actions/setup-node": "node",
    "actions/setup-java": "java",
    "dtolnay/rust-toolchain": "cargo",
    "gradle/actions/setup-gradle": "java",
}

# THE `shell` COLUMN, and why it is emitted rather than assumed by the caller. GitHub's DEFAULT shell for
# `run:` on Linux and macOS is `bash -e {0}`; an explicit `shell: bash` is
# `bash --noprofile --norc -eo pipefail {0}`. The difference is not cosmetic: release-scripts.yml's "parse
# every release script" step is a loop whose body is `bash -n "$f" && echo "  ok  $f"`, and `-e` decides
# whether the step is a gate or a printout. (It turned out to be a printout either way — `set -e` does not
# fire for a command on the LEFT of `&&` — which is how that vacuous gate was found; but a runner that
# guessed the shell would not have been able to reason about it at all.)
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
# An `if:` this evaluator understands is built only from these tokens. Anything else — a function call,
# `github.ref`, a matrix reference — is UNEVALUABLE, and an unevaluable condition makes the job SKIP with
# that as the reason. Guessing would run a job GitHub would not, and a false red in a pre-push gate is
# how a gate gets switched off.
IF_SAFE = re.compile(r"^[\s()!'\"a-zA-Z0-9_.=|&-]*$")


def b64(s):
    return base64.b64encode((s or "").encode("utf-8")).decode("ascii")


def eval_if(expr, event):
    """`true` / `false` / None (unevaluable). Only `github.event_name` is bound."""
    if expr is None:
        return True
    e = str(expr).strip()
    if e in ("true", "false"):
        return e == "true"
    if not IF_SAFE.match(e):
        return None
    if "github." in e and "github.event_name" not in e:
        return None
    py = e.replace("github.event_name", repr(event)).replace("&&", " and ").replace("||", " or ")
    py = re.sub(r"!(?=[\s(a-zA-Z'\"])", " not ", py)
    try:
        return bool(eval(py, {"__builtins__": {}}, {}))       # noqa: S307 - token-whitelisted above
    except Exception:
        return None


def triggers(wf):
    """`on:` is YAML 1.1's boolean `true`, so the key is not the string you wrote."""
    return wf.get("on", wf.get(True, {})) or {}


def flatten_env(*layers):
    out = {}
    for layer in layers:
        for k, v in (layer or {}).items():
            out[str(k)] = "" if v is None else str(v)
    return out


def host_os():
    return "darwin" if sys.platform == "darwin" else "linux"


def runs_on_os(runs_on):
    r = " ".join(runs_on) if isinstance(runs_on, list) else str(runs_on or "")
    if "macos" in r:
        return "darwin"
    if "windows" in r:
        return "windows"
    return "linux"


# US (0x1f), NOT TAB. A tab is IFS whitespace to bash, so `IFS=$'\t' read` COLLAPSES runs of them and
# every empty field vanishes — which silently shifts every later column left. Measured here on the first
# run: an empty `working-directory` made the shell name arrive as the directory and `cd wt/default`
# failed, reporting two green steps as red. A separator that is not whitespace cannot do that.
SEP = "\x1f"


def emit(rec):
    sys.stdout.write(SEP.join(rec) + "\n")


def steps_of(path, event, target_os):
    fn = os.path.basename(path)
    try:
        wf = yaml.safe_load(open(path, encoding="utf-8")) or {}
    except Exception as exc:                                   # a workflow we cannot read is a finding
        emit(["SKIP", fn, fn, "-", "-", "(whole file)",
              f"unparseable workflow: {exc.__class__.__name__}", "", "", b64(""), b64("")])
        return

    name = str(wf.get("name", fn))
    on = triggers(wf)
    local = [t for t in ("push", "pull_request") if t in on]
    wf_env = wf.get("env") or {}
    wf_wd = ((wf.get("defaults") or {}).get("run") or {}).get("working-directory", "")

    for job_id, job in (wf.get("jobs") or {}).items():
        job = job or {}
        runs_on = job.get("runs-on", "")
        job_os = runs_on_os(runs_on)
        job_env = job.get("env") or {}
        job_wd = ((job.get("defaults") or {}).get("run") or {}).get("working-directory", wf_wd)
        cond = eval_if(job.get("if"), event)

        # Reasons that disqualify the WHOLE job, in the order they are decided. Each is attached to
        # every step of that job rather than to the job, so the step-level ledger stays complete: a
        # caller counting rows sees the same number whether or not the job ran.
        job_skip = None
        job_advisory = ""
        if not local:
            job_skip = (f"{fn} has no push/pull_request trigger "
                        f"({', '.join(sorted(str(k) for k in on)) or 'no triggers'}) — a scheduled "
                        f"monitor, not a pre-push gate")
        elif cond is None:
            job_skip = f"job `if: {job.get('if')}` could not be evaluated for event={event}"
        elif cond is False:
            job_skip = f"job `if: {job.get('if')}` is false for event={event}"
        elif job_os == "windows" and target_os != "windows":
            job_skip = f"declares runs-on: {runs_on} — a Windows job has no approximation here"
        elif job_os != target_os:
            job_advisory = f"PLATFORM: a {runs_on} job, run on {target_os}"

        for i, st in enumerate(job.get("steps") or []):
            st = st or {}
            label = str(st.get("name") or st.get("uses") or f"step {i + 1}")
            env = flatten_env(wf_env, job_env, st.get("env"))
            wd = st.get("working-directory", job_wd) or ""
            shell = "bash" if st.get("shell") == "bash" else "default"
            row = [fn, name, str(job_id), (" ".join(runs_on) if isinstance(runs_on, list)
                                           else str(runs_on)), label]

            if "uses" in st:
                action = str(st["uses"]).split("@")[0]
                tool = PROVISION_TOOL.get(action, "")
                why = (f"`uses: {st['uses']}` — runner environment, no local execution"
                       + (f"; provides `{tool}`" if tool else "; no local tool asserted"))
                emit(["PROVISION"] + row + [why, tool, "", b64(""), b64("")])
                continue

            script = st.get("run")
            if script is None:
                emit(["SKIP"] + row + ["unclassifiable: neither `run:` nor `uses:`", wd, shell,
                                       b64(""), b64("")])
                continue

            reason = job_skip
            if reason is None:
                st_cond = eval_if(st.get("if"), event)
                if st_cond is None:
                    reason = f"step `if: {st.get('if')}` could not be evaluated"
                elif st_cond is False:
                    reason = f"step `if: {st.get('if')}` is false for event={event}"
            if reason is None:
                blob = script + " " + " ".join(f"{k}={v}" for k, v in env.items())
                if "secrets." in blob:
                    reason = "needs a repository SECRET, which is not on this machine by design"
                else:
                    exprs = [m.strip() for m in EXPR.findall(blob)]
                    unresolved = [e for e in exprs if not e.startswith("github.workspace")]
                    if unresolved:
                        reason = ("uses a GitHub expression this runner cannot resolve: "
                                  + "${{ " + unresolved[0] + " }}")

            env_pairs = "\n".join(f"{k}={v}" for k, v in env.items())
            status = "SKIP" if reason else "RUN"
            emit([status] + row + [reason or job_advisory, wd, shell, b64(env_pairs), b64(script)])


def main(argv):
    repo = argv[1] if len(argv) > 1 else "."
    event, target = "push", host_os()
    for i, a in enumerate(argv):
        if a == "--event" and i + 1 < len(argv):
            event = argv[i + 1]
        if a == "--os" and i + 1 < len(argv):
            target = argv[i + 1]
    wfdir = os.path.join(repo, ".github", "workflows")
    if not os.path.isdir(wfdir):
        sys.stderr.write(f"wf-steps: no .github/workflows under {repo}\n")
        return 2
    found = 0
    for fn in sorted(os.listdir(wfdir)):
        if fn.endswith((".yml", ".yaml")):
            found += 1
            steps_of(os.path.join(wfdir, fn), event, target)
    if not found:
        sys.stderr.write(f"wf-steps: {wfdir} holds no workflow files\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
