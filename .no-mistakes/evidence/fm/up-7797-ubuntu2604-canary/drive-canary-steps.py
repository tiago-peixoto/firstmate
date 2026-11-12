#!/usr/bin/env python3
"""Run the tests-ubuntu-26-canary job's run steps from .github/workflows/ci.yml
on this Linux host, against the real bin/fm-test-run.sh and real suites.

Local deviations from the hosted job, all stated in the transcript:
- the suites step keeps its command verbatim but runs only the first N listed suites
  (the full ten need 35-55 minutes), and optionally a different per-suite bound;
- the tasks-axi step skips `npm install -g` (it would change machine-global state).
Usage: drive-canary-steps.py <ci.yml> <outdir> <suite-count> [per-suite-bound-secs]
"""
import os, re, subprocess, sys, yaml
wf, out, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
bound = sys.argv[4] if len(sys.argv) > 4 else None
os.makedirs(out + "/runner-temp", exist_ok=True)
job = yaml.safe_load(open(wf))["jobs"]["tests-ubuntu-26-canary"]
print(f"job: runs-on={job['runs-on']} continue-on-error={job['continue-on-error']} timeout-minutes={job['timeout-minutes']}")
env = dict(os.environ, RUNNER_TEMP=out + "/runner-temp", GITHUB_STEP_SUMMARY=out + "/summary.md")
outcomes, conclusion = {}, "success"
for step in job["steps"]:
    if "run" not in step:
        continue
    script, sid = step["run"], step.get("id")
    if sid == "tasks_axi":
        script = script.replace("npm install -g tasks-axi\n", "")
    if sid == "suites":
        lines = script.splitlines()
        suites = [l for l in lines if l.strip().startswith("tests/")]
        kept = suites[:count]
        kept[-1] = kept[-1].rstrip(" \\")
        script = "\n".join([l for l in lines if l not in suites] + kept) + "\n"
        if bound:
            script = script.replace("--per-script-timeout-secs 1500", f"--per-script-timeout-secs {bound}")
    senv = dict(env)
    for k, v in step.get("env", {}).items():
        senv[k] = re.sub(r"\$\{\{ steps\.(\w+)\.outcome \}\}", lambda m: outcomes[m.group(1)], v)
    print(f"\n##[group] step: {step['name']}\n$ " + script.rstrip().replace("\n", "\n$ "), flush=True)
    rc = subprocess.run(["bash", "-e", "-c", script], env=senv).returncode
    ok = rc == 0
    if sid:
        outcomes[sid] = "success" if ok else "failure"
    if not ok and step.get("continue-on-error") is not True:
        conclusion = "failure"
    print(f"##[endgroup] exit={rc} outcome={'success' if ok else 'failure'}", flush=True)
print(f"\njob check conclusion: {conclusion}\n\n--- job summary ($GITHUB_STEP_SUMMARY) ---")
print(open(out + "/summary.md").read())
