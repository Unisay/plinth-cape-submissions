"""Failure cases for the CI contract; no network or Nix required."""

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("uplc_check", Path(__file__).with_name("check.py"))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

ARTIFACT = "submissions/example/Compiler/example.uplc"


class CIContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_empty_build_fails(self):
        with self.assertRaisesRegex(ci.CheckError, "No UPLC"):
            ci.inventory(self.root)

    def test_empty_and_symlink_emissions_fail(self):
        artifact = self.root / ARTIFACT
        artifact.parent.mkdir(parents=True)
        artifact.touch()
        with self.assertRaisesRegex(ci.CheckError, "Empty"):
            ci.inventory(self.root)
        artifact.unlink()
        target = self.root / "outside"
        target.write_text("UPLC")
        artifact.symlink_to(target)
        with self.assertRaisesRegex(ci.CheckError, "symlink"):
            ci.inventory(self.root)

    def test_unknown_base_fails(self):
        with self.assertRaisesRegex(ci.CheckError, "No CI profile"):
            ci.configuration("unknown-compiler")

    def test_suite_coverage_across_builds(self):
        outputs = {"default": ["submissions/one/c/a.uplc"], "casing": ["submissions/two/c/b.uplc"]}
        ci.check_coverage(outputs, ["one", "two"], {})
        with self.assertRaisesRegex(ci.CheckError, "No emitted artifact"):
            ci.check_coverage(outputs, ["one", "two", "three"], {})
        with self.assertRaisesRegex(ci.CheckError, "No suite or exclusion"):
            ci.check_coverage(outputs, ["one"], {})
        ci.check_coverage(outputs, ["one"], {"two": "Older contract"})
        with self.assertRaisesRegex(ci.CheckError, "excluded scenarios"):
            ci.check_coverage(outputs, ["one", "two"], {"obsolete": "Older contract"})
        with self.assertRaisesRegex(ci.CheckError, "needs a reason"):
            ci.check_coverage(outputs, ["one"], {"two": ""})

    def test_failed_build_is_never_success(self):
        with self.assertRaisesRegex(ci.CheckError, "Command failed"):
            ci.command(["python3", "-c", "raise SystemExit(7)"], self.root, self.root / "build.log")
        self.assertTrue((self.root / "build.log").exists())

    def test_wrong_cape_revision_and_test_hash_fail_before_build(self):
        tests = self.root / "scenarios/example/cape-tests.json"
        tests.parent.mkdir(parents=True)
        tests.write_text("[]")
        config = {"revision": "a" * 40, "suites": {"example": "b" * 64}}
        with patch.object(ci, "git", return_value="c" * 40):
            with self.assertRaisesRegex(ci.CheckError, "wrong commit"):
                ci.cape_measure(config, ["example"], self.root, self.root)
        with patch.object(ci, "git", side_effect=["a" * 40, ""]):
            with self.assertRaisesRegex(ci.CheckError, "hash mismatch"):
                ci.cape_measure(config, ["example"], self.root, self.root)

    def test_wrong_resolved_plugin_or_ghc_fails(self):
        path = self.root / "dist-newstyle/cache/plan.json"
        path.parent.mkdir(parents=True)
        plan = {"compiler-id": "ghc-9.6.7", "install-plan": [
            {"pkg-name": name, "pkg-version": "1.71.0.0"}
            for name in ["plutus-core", "plutus-ledger-api", "plutus-tx", "plutus-tx-plugin"]
        ]}
        profile = {"compiler": "ghc-9.6.7", "plutus_version": "1.71.0.0"}
        path.write_text(json.dumps(plan))
        self.assertEqual(ci.resolved_toolchain(self.root, profile)["compiler"], "ghc-9.6.7")
        plan["install-plan"][-1]["pkg-version"] = "1.45.0.0"
        path.write_text(json.dumps(plan))
        with self.assertRaisesRegex(ci.CheckError, "plutus-tx-plugin"):
            ci.resolved_toolchain(self.root, profile)
        plan["compiler-id"] = "ghc-9.8.4"
        path.write_text(json.dumps(plan))
        with self.assertRaisesRegex(ci.CheckError, "GHC"):
            ci.resolved_toolchain(self.root, profile)

    def test_source_tree_cannot_be_used_as_results_directory(self):
        args = argparse.Namespace(branch="main", source=self.root, results=self.root, mode="verify")
        with self.assertRaisesRegex(ci.CheckError, "outside the source"):
            ci.run(args)
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
