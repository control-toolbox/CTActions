#!/usr/bin/env python3
"""Evaluate .github/ci.toml and event/labels to output workflow flags and parameters."""

import argparse
import json
import os
import secrets
import subprocess
import sys
import tomllib
from pathlib import Path


SCHEMA = {
    "use_ct_registry": bool,
    "ci": {
        "github": {
            "enabled": bool,
            "label": str,
            "versions": list,
            "runs_on": list,
            "test_args": str,
            "fail_fast": bool,
            "scope_script": str,
            "scope_test_dirs": list,
            "results_script": str,
            "upload_artifact_path": str,
            "upload_artifact_name": str,
            "smoke_test": bool,
        },
        "occidata": {
            "enabled": bool,
            "label": str,
            "versions": list,
            "runs_on": list,
            "test_args": str,
            "run_on_push": bool,
        },
        "kkt": {
            "enabled": bool,
            "label": str,
            "versions": list,
            "runs_on": list,
            "test_args": str,
        },
        "gpu_main": {
            "enabled": bool,
            "versions": list,
            "test_args": str,
        },
    },
    "documentation": {
        "enabled": bool,
        "label": str,
        "preview_label": str,
        "gpu_runner": str,
        "gpu_timeout_minutes": (int, float),
    },
    "breakage": {
        "packages": {
            "enabled": bool,
            "label": str,
            "consumers": bool,
            "versions": list,
            "targets": list,
        },
        "applications": {
            "enabled": bool,
            "label": str,
            "consumers": bool,
            "versions": list,
            "targets": list,
        },
    },
    "release_gate": {
        "enabled": bool,
        "julia_lowest": str,
    },
}


def validate_config(cfg: dict, schema: dict = SCHEMA, prefix: str = "") -> None:
    """Validate cfg against schema: reject unknown keys and verify types."""
    if not isinstance(cfg, dict):
        raise TypeError(f"Configuration at '{prefix or 'root'}' must be a dictionary/table, got {type(cfg).__name__}")

    for k, v in cfg.items():
        field_path = f"{prefix}.{k}" if prefix else k
        if k not in schema:
            allowed = ", ".join(f"'{a}'" for a in sorted(schema.keys()))
            raise ValueError(f"Unknown key '{field_path}' in ci.toml. Allowed keys at this level: {allowed}")

        expected = schema[k]
        if isinstance(expected, dict):
            if not isinstance(v, dict):
                raise TypeError(f"Section '{field_path}' must be a table, got {type(v).__name__}")
            validate_config(v, expected, field_path)
        else:
            if not isinstance(v, expected):
                exp_names = expected.__name__ if isinstance(expected, type) else "/".join(t.__name__ for t in expected)
                raise TypeError(f"Field '{field_path}' must be of type {exp_names}, got {type(v).__name__}")


def load_config(config_path: Path) -> dict:
    """Load .github/ci.toml if present, validating keys and returning merged defaults."""
    cfg = {}
    if config_path.is_file():
        with open(config_path, "rb") as f:
            cfg = tomllib.load(f)
        validate_config(cfg)

    # Defaults
    defaults = {
        "use_ct_registry": True,
        "ci": {
            "github": {
                "enabled": True,
                "label": "run ci github-runner",
                "versions": ["1.10", "1.13"],
                "runs_on": ["ubuntu-latest", "macos-latest", "windows-latest"],
                "test_args": "",
                "fail_fast": True,
                "scope_script": "",
                "scope_test_dirs": [],
                "results_script": "",
                "upload_artifact_path": "",
                "upload_artifact_name": "",
                "smoke_test": False,
            },
            "occidata": {
                "enabled": False,
                "label": "run ci occidata-runner",
                "versions": ["1"],
                "runs_on": [["occidata"]],
                "test_args": "",
                "run_on_push": False,
            },
            "kkt": {
                "enabled": False,
                "label": "run ci kkt-runner",
                "versions": ["1"],
                "runs_on": [["kkt"]],
                "test_args": "",
            },
            "gpu_main": {
                "enabled": False,
                "versions": ["1"],
                "test_args": "",
            },
        },
        "documentation": {
            "enabled": True,
            "label": "run documentation",
            "preview_label": "documentation push preview",
            "gpu_runner": "",
            "gpu_timeout_minutes": 120,
        },
        "breakage": {
            "packages": {
                "enabled": True,
                "label": "run breakage",
                "consumers": True,
                "versions": ["latest", "stable"],
                "targets": [],
            },
            "applications": {
                "enabled": False,
                "label": "run breakage applications",
                "consumers": False,
                "versions": ["latest", "stable"],
                "targets": [],
            },
        },
        "release_gate": {
            "enabled": True,
            "julia_lowest": "1.10",
        },
    }

    # Deep merge
    merged = defaults.copy()
    if "use_ct_registry" in cfg:
        merged["use_ct_registry"] = bool(cfg["use_ct_registry"])

    if "ci" in cfg and isinstance(cfg["ci"], dict):
        for k in ("github", "occidata", "kkt", "gpu_main"):
            if k in cfg["ci"] and isinstance(cfg["ci"][k], dict):
                merged["ci"][k].update(cfg["ci"][k])

    if "documentation" in cfg and isinstance(cfg["documentation"], dict):
        merged["documentation"].update(cfg["documentation"])

    if "breakage" in cfg and isinstance(cfg["breakage"], dict):
        for k in ("packages", "applications"):
            if k in cfg["breakage"] and isinstance(cfg["breakage"][k], dict):
                merged["breakage"][k].update(cfg["breakage"][k])

    if "release_gate" in cfg and isinstance(cfg["release_gate"], dict):
        merged["release_gate"].update(cfg["release_gate"])

    return merged


def run_scope_script(
    scope_script: str,
    scope_test_dirs: list[str],
    event: str,
    labels: list[str],
    expected_files: str,
    summary_path: Path | None,
    root: Path,
) -> str:
    """Run scope tests and script, returning computed test_args."""
    script_path = (root / scope_script).resolve()
    if not script_path.is_file():
        print(f"::warning::scope_script '{scope_script}' not found, skipping", file=sys.stderr)
        return ""

    for tdir in scope_test_dirs:
        test_dir = root / tdir
        if test_dir.is_dir():
            print(f"Running scope tests in {tdir}...", file=sys.stderr)
            res = subprocess.run(
                [sys.executable, "-m", "unittest", "discover", "-s", str(test_dir), "-p", "test_*.py", "-v"],
                cwd=str(root),
            )
            if res.returncode != 0:
                raise RuntimeError(f"Scope tests in '{tdir}' failed with exit code {res.returncode}")

    cmd = [sys.executable, str(script_path), "--event", event, "--labels", json.dumps(labels), "--root", str(root)]
    if expected_files:
        cmd.extend(["--expected-files", str(expected_files)])
    if summary_path:
        cmd.extend(["--summary", str(summary_path)])

    print(f"Executing scope script: {' '.join(cmd)}", file=sys.stderr)
    res = subprocess.run(cmd, cwd=str(root), capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"scope_script '{scope_script}' failed with code {res.returncode}: {res.stderr}")

    args = res.stdout.strip()
    print(f"Computed scope test_args: '{args}'", file=sys.stderr)
    return args


def evaluate_dispatch(
    config: dict,
    event: str,
    action: str,
    pr_state: str,
    labels: list[str],
    expected_files: str,
    summary_path: Path | None,
    root: Path,
) -> dict[str, str]:
    """Evaluate config and event to determine job execution and arguments."""
    outputs = {}

    is_pr = (event == "pull_request")
    is_open_pr = (is_pr and pr_state == "open")

    outputs["open"] = "true" if (not is_pr or is_open_pr) else "false"

    # Base flags
    run_release_gate = False
    run_ci_github = False
    run_ci_occidata = False
    run_ci_kkt = False
    run_ci_gpu_main = False
    run_documentation = False
    run_breakage_packages = False
    run_breakage_applications = False

    if is_pr:
        if is_open_pr:
            labels_set = set(labels)

            # Release gate: runs on every open PR if enabled
            if config["release_gate"]["enabled"]:
                run_release_gate = True

            # CI GitHub
            gh_cfg = config["ci"]["github"]
            if gh_cfg["enabled"] and gh_cfg["label"] in labels_set:
                run_ci_github = True

            # CI Occidata
            occi_cfg = config["ci"]["occidata"]
            if occi_cfg["enabled"] and occi_cfg["label"] in labels_set:
                run_ci_occidata = True

            # CI KKT
            kkt_cfg = config["ci"]["kkt"]
            if kkt_cfg["enabled"] and kkt_cfg["label"] in labels_set:
                run_ci_kkt = True

            # Documentation
            doc_cfg = config["documentation"]
            if doc_cfg["enabled"] and doc_cfg["label"] in labels_set:
                run_documentation = True

            # Breakage packages
            brk_pkg = config["breakage"]["packages"]
            if brk_pkg["enabled"] and brk_pkg["label"] in labels_set:
                run_breakage_packages = True

            # Breakage applications
            brk_app = config["breakage"]["applications"]
            if brk_app["enabled"] and brk_app["label"] in labels_set:
                run_breakage_applications = True
    elif event == "push":
        # Note: In standard repository setup, push on main is handled by CI.yml/Documentation.yml.
        # This fallback is for manual or unified push triggers.
        gh_cfg = config["ci"]["github"]
        if gh_cfg["enabled"]:
            run_ci_github = True

        occi_cfg = config["ci"]["occidata"]
        if occi_cfg["enabled"] and occi_cfg.get("run_on_push", False):
            run_ci_occidata = True

        gpu_main = config["ci"]["gpu_main"]
        if gpu_main["enabled"]:
            run_ci_gpu_main = True

        doc_cfg = config["documentation"]
        if doc_cfg["enabled"]:
            run_documentation = True

        brk_pkg = config["breakage"]["packages"]
        if brk_pkg["enabled"]:
            run_breakage_packages = True
    else:
        # workflow_dispatch / other
        gh_cfg = config["ci"]["github"]
        if gh_cfg["enabled"]:
            run_ci_github = True

    # Compute test_args for CI GitHub
    ci_github_test_args = config["ci"]["github"]["test_args"]
    if run_ci_github and config["ci"]["github"].get("scope_script"):
        computed_args = run_scope_script(
            config["ci"]["github"]["scope_script"],
            config["ci"]["github"].get("scope_test_dirs", []),
            event,
            labels,
            expected_files,
            summary_path,
            root,
        )
        if computed_args:
            ci_github_test_args = computed_args

    # Set boolean output flags
    outputs["run_release_gate"] = "true" if run_release_gate else "false"
    outputs["run_ci_github"] = "true" if run_ci_github else "false"
    outputs["run_ci_occidata"] = "true" if run_ci_occidata else "false"
    outputs["run_ci_kkt"] = "true" if run_ci_kkt else "false"
    outputs["run_ci_gpu_main"] = "true" if run_ci_gpu_main else "false"
    outputs["run_documentation"] = "true" if run_documentation else "false"
    outputs["run_breakage_packages"] = "true" if run_breakage_packages else "false"
    outputs["run_breakage_applications"] = "true" if run_breakage_applications else "false"

    # Set parameter outputs
    outputs["use_ct_registry"] = "true" if config["use_ct_registry"] else "false"

    # GitHub CI inputs
    gh_cfg = config["ci"]["github"]
    outputs["ci_github_versions"] = json.dumps(gh_cfg["versions"])
    outputs["ci_github_runs_on"] = json.dumps(gh_cfg["runs_on"])
    outputs["ci_github_test_args"] = ci_github_test_args
    outputs["ci_github_fail_fast"] = "true" if gh_cfg["fail_fast"] else "false"
    outputs["ci_github_upload_artifact_path"] = gh_cfg.get("upload_artifact_path", "")
    outputs["ci_github_upload_artifact_name"] = gh_cfg.get("upload_artifact_name", "")
    outputs["ci_github_smoke_test"] = "true" if gh_cfg.get("smoke_test", False) else "false"

    # Occidata CI inputs
    occi_cfg = config["ci"]["occidata"]
    outputs["ci_occidata_versions"] = json.dumps(occi_cfg["versions"])
    outputs["ci_occidata_runs_on"] = json.dumps(occi_cfg["runs_on"])
    outputs["ci_occidata_test_args"] = occi_cfg.get("test_args", "")

    # KKT CI inputs
    kkt_cfg = config["ci"]["kkt"]
    outputs["ci_kkt_versions"] = json.dumps(kkt_cfg["versions"])
    outputs["ci_kkt_runs_on"] = json.dumps(kkt_cfg["runs_on"])
    outputs["ci_kkt_test_args"] = kkt_cfg.get("test_args", "")

    # GPU Main CI inputs
    gpu_main = config["ci"]["gpu_main"]
    outputs["ci_gpu_main_versions"] = json.dumps(gpu_main["versions"])
    outputs["ci_gpu_main_test_args"] = gpu_main.get("test_args", "")

    # Documentation inputs
    doc_cfg = config["documentation"]
    outputs["documentation_gpu_runner"] = doc_cfg.get("gpu_runner", "")
    outputs["documentation_gpu_timeout_minutes"] = str(doc_cfg.get("gpu_timeout_minutes", 120))

    # Breakage packages inputs
    brk_pkg = config["breakage"]["packages"]
    outputs["breakage_packages_consumers"] = "true" if brk_pkg.get("consumers", True) else "false"
    outputs["breakage_packages_versions"] = json.dumps(brk_pkg["versions"])
    outputs["breakage_packages_targets"] = json.dumps(brk_pkg.get("targets", []))

    # Breakage applications inputs
    brk_app = config["breakage"]["applications"]
    outputs["breakage_applications_consumers"] = "true" if brk_app.get("consumers", False) else "false"
    outputs["breakage_applications_versions"] = json.dumps(brk_app["versions"])
    outputs["breakage_applications_targets"] = json.dumps(brk_app.get("targets", []))

    # Release gate inputs
    outputs["release_gate_julia_lowest"] = config["release_gate"].get("julia_lowest", "1.10")

    return outputs


def write_github_output(output_path: Path, outputs: dict[str, str]) -> None:
    """Safely append key-value pairs to GITHUB_OUTPUT, supporting multi-line strings."""
    with open(output_path, "a", encoding="utf-8") as f:
        for k, v in outputs.items():
            val = str(v)
            if "\n" in val:
                delim = f"DELIMITER_{secrets.token_hex(8)}"
                f.write(f"{k}<<{delim}\n{val}\n{delim}\n")
            else:
                f.write(f"{k}={val}\n")


def generate_summary(outputs: dict[str, str], event: str, pr_state: str, labels: list[str]) -> str:
    """Generate Markdown summary table for GITHUB_STEP_SUMMARY."""
    lines = [
        "## CI Dispatch Summary",
        "",
        f"- **Event**: `{event}`",
    ]
    if event == "pull_request":
        lines.append(f"- **PR State**: `{pr_state}`")
        label_str = ", ".join(f"`{l}`" for l in labels) if labels else "*(none)*"
        lines.append(f"- **Labels**: {label_str}")

    lines.extend([
        "",
        "| Job | Run? | Details |",
        "| --- | :---: | --- |",
        f"| **Release Gate** | {'✅' if outputs['run_release_gate'] == 'true' else '⏭️'} | Lowest Julia: `{outputs['release_gate_julia_lowest']}` |",
        f"| **CI (GitHub)** | {'✅' if outputs['run_ci_github'] == 'true' else '⏭️'} | Versions: `{outputs['ci_github_versions']}`, `test_args`: `\"{outputs['ci_github_test_args']}\"` |",
        f"| **CI (Occidata GPU)** | {'✅' if outputs['run_ci_occidata'] == 'true' else '⏭️'} | Versions: `{outputs['ci_occidata_versions']}` |",
        f"| **CI (KKT GPU)** | {'✅' if outputs['run_ci_kkt'] == 'true' else '⏭️'} | Versions: `{outputs['ci_kkt_versions']}` |",
        f"| **CI (GPU Main)** | {'✅' if outputs['run_ci_gpu_main'] == 'true' else '⏭️'} | Versions: `{outputs['ci_gpu_main_versions']}` |",
        f"| **Documentation** | {'✅' if outputs['run_documentation'] == 'true' else '⏭️'} | GPU runner: `\"{outputs['documentation_gpu_runner']}\"` |",
        f"| **Breakage (Packages)** | {'✅' if outputs['run_breakage_packages'] == 'true' else '⏭️'} | Consumers: `{outputs['breakage_packages_consumers']}` |",
        f"| **Breakage (Applications)** | {'✅' if outputs['run_breakage_applications'] == 'true' else '⏭️'} | Targets: `{outputs['breakage_applications_targets']}` |",
        "",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=".github/ci.toml", type=Path, help="Path to .github/ci.toml")
    parser.add_argument("--event", default="pull_request", help="GitHub event name")
    parser.add_argument("--action", default="", help="Event action (e.g. opened, labeled)")
    parser.add_argument("--pr-state", default="open", help="PR state (open, closed)")
    parser.add_argument("--labels", default="[]", help="JSON array of PR labels")
    parser.add_argument("--expected-files", default="", help="Expected changed files count")
    parser.add_argument("--root", default=Path("."), type=Path, help="Repository root directory")
    parser.add_argument("--output", type=Path, help="File to append outputs to (defaults to GITHUB_OUTPUT)")
    parser.add_argument("--summary", type=Path, help="File to append summary to (defaults to GITHUB_STEP_SUMMARY)")

    args = parser.parse_args()

    try:
        labels_list = json.loads(args.labels) if args.labels else []
    except json.JSONDecodeError:
        print(f"::warning::Could not decode labels JSON: {args.labels!r}", file=sys.stderr)
        labels_list = []

    output_path = args.output or (Path(os.environ["GITHUB_OUTPUT"]) if "GITHUB_OUTPUT" in os.environ else None)
    summary_path = args.summary or (Path(os.environ["GITHUB_STEP_SUMMARY"]) if "GITHUB_STEP_SUMMARY" in os.environ else None)

    config_file = args.root / args.config if not args.config.is_absolute() else args.config
    try:
        cfg = load_config(config_file)
    except (ValueError, TypeError, tomllib.TOMLDecodeError) as e:
        print(f"::error file={config_file}::{e}", file=sys.stderr)
        sys.exit(1)

    try:
        outputs = evaluate_dispatch(
            cfg,
            event=args.event,
            action=args.action,
            pr_state=args.pr_state,
            labels=labels_list,
            expected_files=args.expected_files,
            summary_path=summary_path,
            root=args.root,
        )
    except RuntimeError as e:
        print(f"::error::{e}", file=sys.stderr)
        sys.exit(1)

    # Write to output file or stdout
    if output_path:
        write_github_output(output_path, outputs)
    else:
        for k, v in outputs.items():
            print(f"{k}={v}")

    # Write to summary
    if summary_path:
        summary_md = generate_summary(outputs, args.event, args.pr_state, labels_list)
        with open(summary_path, "a", encoding="utf-8") as f:
            f.write(summary_md)


if __name__ == "__main__":
    main()
