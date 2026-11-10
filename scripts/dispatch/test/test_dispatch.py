#!/usr/bin/env python3
"""Unit tests for scripts/dispatch/dispatch.py."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Allow direct execution: python3 scripts/dispatch/test/test_dispatch.py
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.dispatch.dispatch import evaluate_dispatch, load_config, write_github_output


class TestDispatch(unittest.TestCase):
    def test_default_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = load_config(Path(tmpdir) / "nonexistent.toml")
            self.assertTrue(cfg["use_ct_registry"])
            self.assertTrue(cfg["ci"]["github"]["enabled"])
            self.assertEqual(cfg["ci"]["github"]["label"], "run ci github-runner")
            self.assertEqual(cfg["ci"]["github"]["versions"], ["1.10", "1.13"])
            self.assertFalse(cfg["ci"]["occidata"]["enabled"])
            self.assertTrue(cfg["documentation"]["enabled"])
            self.assertTrue(cfg["breakage"]["packages"]["enabled"])
            self.assertFalse(cfg["breakage"]["applications"]["enabled"])
            self.assertTrue(cfg["release_gate"]["enabled"])

    def test_custom_config_merge(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = Path(tmpdir) / "ci.toml"
            cfg_file.write_text(
                """
use_ct_registry = false

[ci.github]
versions = ["1.13"]
runs_on = ["ubuntu-latest"]
test_args = "core"
smoke_test = true

[ci.occidata]
enabled = true
test_args = "GPU"

[breakage.applications]
enabled = true
targets = [{name = "Tutorials", break = "doc"}]

[release_gate]
julia_lowest = "1.11"
"""
            )
            cfg = load_config(cfg_file)
            self.assertFalse(cfg["use_ct_registry"])
            self.assertEqual(cfg["ci"]["github"]["versions"], ["1.13"])
            self.assertEqual(cfg["ci"]["github"]["runs_on"], ["ubuntu-latest"])
            self.assertEqual(cfg["ci"]["github"]["test_args"], "core")
            self.assertTrue(cfg["ci"]["github"]["smoke_test"])
            self.assertTrue(cfg["ci"]["occidata"]["enabled"])
            self.assertEqual(cfg["ci"]["occidata"]["test_args"], "GPU")
            self.assertTrue(cfg["breakage"]["applications"]["enabled"])
            self.assertEqual(cfg["breakage"]["applications"]["targets"], [{"name": "Tutorials", "break": "doc"}])
            self.assertEqual(cfg["release_gate"]["julia_lowest"], "1.11")

    def test_invalid_config_unknown_key(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = Path(tmpdir) / "ci.toml"
            cfg_file.write_text("""
[ci.github]
versions = ["1.10"]
unknown_setting = true
""")
            with self.assertRaises(ValueError) as ctx:
                load_config(cfg_file)
            self.assertIn("Unknown key 'ci.github.unknown_setting'", str(ctx.exception))

    def test_invalid_config_wrong_type(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = Path(tmpdir) / "ci.toml"
            cfg_file.write_text("""
[ci.github]
versions = "1.10"
""")
            with self.assertRaises(TypeError) as ctx:
                load_config(cfg_file)
            self.assertIn("Field 'ci.github.versions' must be of type list", str(ctx.exception))

    def test_pr_closed_exits_early(self):
        cfg = load_config(Path("nonexistent.toml"))
        outputs = evaluate_dispatch(
            cfg,
            event="pull_request",
            action="labeled",
            pr_state="closed",
            labels=["run ci github-runner", "run documentation", "run breakage"],
            expected_files="",
            summary_path=None,
            root=Path("."),
        )
        self.assertEqual(outputs["open"], "false")
        self.assertEqual(outputs["run_release_gate"], "false")
        self.assertEqual(outputs["run_ci_github"], "false")
        self.assertEqual(outputs["run_ci_occidata"], "false")
        self.assertEqual(outputs["run_ci_kkt"], "false")
        self.assertEqual(outputs["run_ci_gpu_main"], "false")
        self.assertEqual(outputs["run_documentation"], "false")
        self.assertEqual(outputs["run_breakage_packages"], "false")
        self.assertEqual(outputs["run_breakage_applications"], "false")

    def test_pr_open_no_labels(self):
        cfg = load_config(Path("nonexistent.toml"))
        outputs = evaluate_dispatch(
            cfg,
            event="pull_request",
            action="opened",
            pr_state="open",
            labels=[],
            expected_files="",
            summary_path=None,
            root=Path("."),
        )
        self.assertEqual(outputs["open"], "true")
        self.assertEqual(outputs["run_release_gate"], "true")
        self.assertEqual(outputs["run_ci_github"], "false")
        self.assertEqual(outputs["run_ci_occidata"], "false")
        self.assertEqual(outputs["run_documentation"], "false")
        self.assertEqual(outputs["run_breakage_packages"], "false")

    def test_pr_open_with_labels(self):
        cfg = load_config(Path("nonexistent.toml"))
        cfg["ci"]["occidata"]["enabled"] = True
        cfg["breakage"]["applications"]["enabled"] = True

        outputs = evaluate_dispatch(
            cfg,
            event="pull_request",
            action="labeled",
            pr_state="open",
            labels=["run ci github-runner", "run documentation", "run breakage", "run ci occidata-runner", "run breakage applications"],
            expected_files="",
            summary_path=None,
            root=Path("."),
        )
        self.assertEqual(outputs["open"], "true")
        self.assertEqual(outputs["run_release_gate"], "true")
        self.assertEqual(outputs["run_ci_github"], "true")
        self.assertEqual(outputs["run_ci_occidata"], "true")
        self.assertEqual(outputs["run_ci_kkt"], "false")
        self.assertEqual(outputs["run_documentation"], "true")
        self.assertEqual(outputs["run_breakage_packages"], "true")
        self.assertEqual(outputs["run_breakage_applications"], "true")

        # Check parameter JSON encoding
        self.assertEqual(json.loads(outputs["ci_github_versions"]), ["1.10", "1.13"])
        self.assertEqual(json.loads(outputs["ci_github_runs_on"]), ["ubuntu-latest", "macos-latest", "windows-latest"])
        self.assertEqual(outputs["use_ct_registry"], "true")

    def test_custom_label_and_disabled_sections(self):
        cfg = load_config(Path("nonexistent.toml"))
        cfg["ci"]["github"]["label"] = "run ci fast"
        cfg["documentation"]["enabled"] = False

        # Even with 'run documentation' present, documentation is disabled in config
        outputs = evaluate_dispatch(
            cfg,
            event="pull_request",
            action="labeled",
            pr_state="open",
            labels=["run ci fast", "run documentation"],
            expected_files="",
            summary_path=None,
            root=Path("."),
        )
        self.assertEqual(outputs["run_ci_github"], "true")
        self.assertEqual(outputs["run_documentation"], "false")

    def test_multiline_output_delimiter(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out_file = Path(tmpdir) / "github_output"
            outputs = {
                "simple": "hello",
                "multiline": "line1\nline2\nline3",
            }
            write_github_output(out_file, outputs)
            content = out_file.read_text(encoding="utf-8")
            self.assertIn("simple=hello\n", content)
            self.assertIn("multiline<<DELIMITER_", content)
            self.assertIn("line1\nline2\nline3\n", content)

    def test_scope_script_execution(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            scope_py = root / "scope.py"
            scope_py.write_text("""#!/usr/bin/env python3
import sys
print("scoped_test_A scoped_test_B")
""")
            os.chmod(scope_py, 0o755)

            cfg = load_config(Path("nonexistent.toml"))
            cfg["ci"]["github"]["scope_script"] = "scope.py"

            outputs = evaluate_dispatch(
                cfg,
                event="pull_request",
                action="labeled",
                pr_state="open",
                labels=["run ci github-runner"],
                expected_files="",
                summary_path=None,
                root=root,
            )
            self.assertEqual(outputs["run_ci_github"], "true")
            self.assertEqual(outputs["ci_github_test_args"], "scoped_test_A scoped_test_B")

    def test_push_event(self):
        cfg = load_config(Path("nonexistent.toml"))
        cfg["ci"]["gpu_main"]["enabled"] = True

        outputs = evaluate_dispatch(
            cfg,
            event="push",
            action="",
            pr_state="",
            labels=[],
            expected_files="",
            summary_path=None,
            root=Path("."),
        )
        self.assertEqual(outputs["open"], "true")
        self.assertEqual(outputs["run_release_gate"], "false")
        self.assertEqual(outputs["run_ci_github"], "true")
        self.assertEqual(outputs["run_ci_gpu_main"], "true")
        self.assertEqual(outputs["run_documentation"], "true")
        self.assertEqual(outputs["run_breakage_packages"], "true")


if __name__ == "__main__":
    unittest.main()
