#!/usr/bin/env python3
"""Build Plinth submissions and validate the emitted UPLC programs."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import time


CONFIG = Path(__file__).resolve().parents[1] / "benchmarks/profiles.json"


class CheckError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise CheckError(f"Cannot read {path}: {error}") from error


def configuration(branch):
    config = read_json(CONFIG)
    require(config.get("schema") == 2, "Unsupported CI profile schema")
    require(branch in config["branches"], f"No CI profile for base {branch!r}; add one explicitly")
    return config, config["branches"][branch]


def git(source, *arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments], text=True).strip()


def resolved_toolchain(source, profile):
    plan = read_json(source / "dist-newstyle/cache/plan.json")
    require(plan.get("compiler-id") == profile["compiler"],
            f"Resolved GHC differs from declared {profile['compiler']}")
    versions = {}
    for name in ["plutus-core", "plutus-ledger-api", "plutus-tx", "plutus-tx-plugin"]:
        found = {item.get("pkg-version") for item in plan["install-plan"] if item.get("pkg-name") == name}
        require(found == {profile["plutus_version"]},
                f"Resolved {name} versions {found} differ from declared {profile['plutus_version']}")
        versions[name] = sorted(found)
    return {"compiler": plan["compiler-id"], "packages": versions}


def inventory(directory):
    files = []
    for path in sorted(directory.rglob("*.uplc")):
        require(not path.is_symlink(), f"Emitted artifact is a symlink: {path}")
        require(path.is_file() and path.stat().st_size > 0, f"Empty or invalid emitted artifact: {path}")
        relative = path.relative_to(directory).as_posix()
        require(relative.startswith("submissions/"), f"Unexpected output location: {relative}")
        files.append(relative)
    require(files, f"No UPLC artifacts emitted into {directory}")
    return files


def command(arguments, cwd, log, env=None):
    started = time.monotonic()
    with log.open("w") as output:
        output.write(json.dumps(arguments) + "\n")
        output.flush()
        result = subprocess.run(arguments, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    require(result.returncode == 0, f"Command failed ({result.returncode}); see {log}")
    return round(time.monotonic() - started, 3)


def cape_measure(config, suites, checkout, results):
    require(checkout is not None, "Configured suites require --cape pointing to the pinned CAPE checkout")
    revision = config["revision"]
    require(isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision),
            "CAPE must be pinned to its durable main-branch merge commit before CI publication")
    require(git(checkout, "rev-parse", "HEAD") == revision, "CAPE checkout is at the wrong commit")
    require(not git(checkout, "status", "--porcelain", "--untracked-files=all"), "CAPE checkout must be clean")
    tests = {}
    for scenario in suites:
        require(re.fullmatch(r"[A-Za-z0-9_-]+", scenario) and scenario in config["suites"],
                f"Unknown CAPE suite: {scenario}")
        suite = checkout / "scenarios" / scenario / "cape-tests.json"
        require(digest(suite) == config["suites"][scenario], f"CAPE test hash mismatch: {scenario}")
        tests[scenario] = suite
    log = results / "build-measure.log"
    # Keep stdout machine-readable while storing all diagnostics beside the artifacts.
    with log.open("w") as output:
        process = subprocess.run([
            "nix", "build", "--accept-flake-config", "--no-link", "--print-out-paths", ".#measure",
        ], cwd=checkout, stdout=subprocess.PIPE, stderr=output, text=True)
    require(process.returncode == 0, f"CAPE evaluator build failed; see {log}")
    paths = process.stdout.splitlines()
    require(len(paths) == 1 and Path(paths[0]).is_absolute(), "Unexpected measure build output")
    executable = Path(paths[0]) / "bin/measure"
    require(executable.is_file(), "Built measure executable is missing")
    return executable, tests


def run(args):
    started = time.monotonic()
    source, results = args.source.resolve(), args.results.resolve()
    config, profile = configuration(args.branch)
    require(source.is_dir(), "Source checkout is missing")
    require(results != source and results not in source.parents and source not in results.parents,
            "Use a results directory outside the source checkout")
    require(not results.exists() or not any(results.iterdir()), "Results directory must be empty")
    results.mkdir(parents=True, exist_ok=True)
    args.results_owned = True
    actual, timings, tested, toolchains = {}, {}, [], {}
    # All invocations, including CAPE, share one lock and run strictly sequentially.
    lock_path = Path("/tmp") / f"plinth-cape-cabal-index-{os.getuid()}.lock"
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        evaluator = (cape_measure(config["cape"], profile["suites"], args.cape.resolve() if args.cape else None, results)
                     if profile["suites"] else None)
        for build in profile["builds"]:
            name = build["name"]
            stage = results / name
            stage.mkdir()
            environment = os.environ.copy()
            environment["CAPE_REPO"] = str(stage)
            timings[name] = command([
                "nix", "develop", "--accept-flake-config", "--command", "cabal", *build["arguments"],
            ], source, results / f"build-{name}.log", environment)
            toolchains[name] = resolved_toolchain(source, profile)
            actual[name] = inventory(stage)
            project_options = [arg for arg in build["arguments"] if arg.startswith(("--project-file=", "--flags="))]
            command([
                "nix", "develop", "--accept-flake-config", "--command", "cabal", *project_options,
                "exec", "--", "runghc",
                str(Path(__file__).resolve().with_name("Validate.hs")), *[str(stage / path) for path in actual[name]],
            ], source, results / f"validate-{name}.log")
            if evaluator:
                measure, suites = evaluator
                for scenario, suite in suites.items():
                    artifacts = [path for path in actual[name] if PurePosixPath(path).parts[1] == scenario]
                    require(artifacts, f"No artifact for CAPE suite {scenario} in {name}")
                    for relative in artifacts:
                        output = results / "evaluations" / name / relative
                        output.parent.mkdir(parents=True, exist_ok=True)
                        command([str(measure), "-i", str(stage / relative), "-t", str(suite),
                                 "-o", str(output.with_suffix(".json"))],
                                source, output.with_suffix(".log"))
                        tested.append(name + "/" + relative)
            print(f"{name}: {len(actual[name])} artifacts, {timings[name]}s", flush=True)
    summary = {"base": args.branch, "source_revision": git(source, "rev-parse", "HEAD"),
               "build_seconds": timings, "outputs": actual,
               "total_seconds": round(time.monotonic() - started, 3),
               "resolved_toolchains": toolchains,
               "evaluated_outputs": tested}
    (results / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["verify", "prepare"])
    parser.add_argument("--branch", required=True, help="PR base branch")
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--results", type=Path)
    parser.add_argument("--cape", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            config, profile = configuration(args.branch)
            print("cape_revision=" + (config["cape"]["revision"] if profile["suites"] else ""))
            return
        require(args.results is not None, "--results is required")
        run(args)
    except (CheckError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"CI failed: {error}", file=sys.stderr)
        if getattr(args, "results_owned", False):
            (args.results / "failure.txt").write_text(str(error) + "\n")
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
