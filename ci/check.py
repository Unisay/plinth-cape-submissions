#!/usr/bin/env python3
"""Build branch-declared Plinth outputs and verify their reviewed byte hashes."""

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


CONFIG = Path(__file__).with_name("profiles.json")


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
    require(config.get("schema") == 1, "Unsupported CI profile schema")
    require(branch in config["branches"], f"No CI profile for base {branch!r}; add one explicitly")
    return config, config["branches"][branch]


def git(source, *arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments], text=True).strip()


def cache_key(source, branch):
    configuration(branch)
    names = git(source, "ls-files", "-z").split("\0")
    inputs = sorted(name for name in names if (
        name in {"flake.nix", "flake.lock", "cabal.project", "cabal.project.preview"}
        or name.endswith((".cabal", ".freeze"))
    ))
    require(inputs, "No pinned build inputs found")
    hasher = hashlib.sha256()
    for name in inputs:
        hasher.update(name.encode() + b"\0" + (source / name).read_bytes() + b"\0")
    return "cabal-" + branch.replace("/", "-") + "-" + hasher.hexdigest()


def inventory(directory):
    files = {}
    for path in sorted(directory.rglob("*.uplc")):
        require(not path.is_symlink(), f"Emitted artifact is a symlink: {path}")
        require(path.is_file() and path.stat().st_size > 0, f"Empty or invalid emitted artifact: {path}")
        relative = path.relative_to(directory).as_posix()
        require(relative.startswith("submissions/"), f"Unexpected output location: {relative}")
        files[relative] = digest(path)
    require(files, f"No UPLC artifacts emitted into {directory}")
    return files


def validate_manifest(manifest, branch, profile):
    require(manifest.get("schema") == 1 and manifest.get("base") == branch,
            "Expected manifest schema/base does not match this PR base")
    expected = manifest.get("outputs", {})
    require(set(expected) == {build["name"] for build in profile["builds"]},
            "Expected manifest does not cover every declared build invocation")
    for build, files in expected.items():
        require(isinstance(files, dict) and files, f"Empty output declaration for {build}")
        for name, sha in files.items():
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts
                    and name.startswith("submissions/") and name.endswith(".uplc"),
                    f"Invalid expected artifact path: {name}")
            require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha),
                    f"Invalid expected SHA256 for {name}")
    return expected


def compare(expected, actual):
    differences = []
    for name in sorted(set(expected) - set(actual)):
        differences.append("missing: " + name)
    for name in sorted(set(actual) - set(expected)):
        differences.append("extra: " + name)
    for name in sorted(set(actual) & set(expected)):
        if actual[name] != expected[name]:
            differences.append(f"changed: {name} ({expected[name]} -> {actual[name]})")
    require(not differences, "Emitted UPLC differs from its reviewed manifest:\n" + "\n".join(differences))


def command(arguments, cwd, log, env=None):
    started = time.monotonic()
    with log.open("w") as output:
        output.write(json.dumps(arguments) + "\n")
        output.flush()
        result = subprocess.run(arguments, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    require(result.returncode == 0, f"Command failed ({result.returncode}); see {log}")
    return round(time.monotonic() - started, 3)


def cape_measure(config, checkout, results):
    require(checkout is not None, "Revision-2 escrow requires --cape pointing to the pinned CAPE checkout")
    revision = config["revision"]
    require(isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision),
            "CAPE must be pinned to its durable main-branch merge commit before CI publication")
    require(git(checkout, "rev-parse", "HEAD") == revision, "CAPE checkout is at the wrong commit")
    require(not git(checkout, "status", "--porcelain", "--untracked-files=all"), "CAPE checkout must be clean")
    require(digest(checkout / config["tests_path"]) == config["tests_sha256"], "CAPE escrow test hash mismatch")
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
    return executable, checkout / config["tests_path"]


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
    manifest_path = source / "ci/expected-outputs.json"
    expected = None
    if args.mode == "record":
        require(not os.environ.get("CI") and not os.environ.get("GITHUB_ACTIONS"),
                "Recording expected outputs is forbidden in CI")
        require(args.replace or not manifest_path.exists(), "Manifest exists; use --replace for an intentional update")
        require(not git(source, "status", "--porcelain", "--untracked-files=all", "--",
                        "lib", "plinth-submissions-app", "plinth-submissions-preview-app",
                        "flake.nix", "flake.lock", "cabal.project", "cabal.project.preview", "*.cabal"),
                "Commit source/build-input changes before recording their expected outputs")
    else:
        expected = validate_manifest(read_json(manifest_path), args.branch, profile)
    actual, timings, tested = {}, {}, []
    # All invocations, including CAPE, share one lock and run strictly sequentially.
    lock_path = Path("/tmp") / f"plinth-cape-cabal-index-{os.getuid()}.lock"
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        evaluator = cape_measure(config["cape"], args.cape.resolve() if args.cape else None, results) if profile["escrow_revision"] == 2 else None
        for build in profile["builds"]:
            name = build["name"]
            stage = results / name
            stage.mkdir()
            environment = os.environ.copy()
            environment["CAPE_REPO"] = str(stage)
            timings[name] = command([
                "nix", "develop", "--accept-flake-config", "--command", "cabal", *build["arguments"],
            ], source, results / f"build-{name}.log", environment)
            actual[name] = inventory(stage)
            (results / "actual-outputs.json").write_text(json.dumps(actual, indent=2) + "\n")
            if expected is not None:
                compare(expected[name], actual[name])
            if evaluator:
                escrows = [path for path in actual[name] if "/two_party_escrow/" in path]
                require(escrows, f"No revision-2 escrow was emitted by {name}")
                for relative in escrows:
                    artifact = stage / relative
                    label = name + "-" + artifact.parent.name
                    command([str(evaluator[0]), "-i", str(artifact), "-t", str(evaluator[1]),
                             "-o", str(results / f"metrics-{label}.json")],
                            source, results / f"measure-{label}.log")
                    tested.append(name + "/" + relative)
            print(f"{name}: {len(actual[name])} artifacts, {timings[name]}s", flush=True)
    if args.mode == "record":
        manifest_path.parent.mkdir(exist_ok=True)
        manifest_path.write_text(json.dumps({"schema": 1, "base": args.branch, "outputs": actual}, indent=2) + "\n")
    summary = {"base": args.branch, "source_revision": git(source, "rev-parse", "HEAD"),
               "mode": args.mode, "build_seconds": timings, "outputs": actual,
               "total_seconds": round(time.monotonic() - started, 3),
               "escrow_revision": profile["escrow_revision"], "escrows_tested": tested,
               "semantics": "pinned revision-2 suite" if tested else "legacy: reproduction only"}
    (results / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["verify", "record", "prepare"])
    parser.add_argument("--branch", required=True, help="PR base branch")
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--results", type=Path)
    parser.add_argument("--cape", type=Path)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            config, _ = configuration(args.branch)
            print("cache_key=" + cache_key(args.source.resolve(), args.branch))
            print("cape_revision=" + (config["cape"]["revision"] or ""))
            print("escrow_revision=" + str(config["branches"][args.branch]["escrow_revision"]))
            return
        require(args.results is not None, "--results is required")
        summary = run(args)
        print(summary["semantics"])
    except (CheckError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"CI failed: {error}", file=sys.stderr)
        if getattr(args, "results_owned", False):
            (args.results / "failure.txt").write_text(str(error) + "\n")
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
