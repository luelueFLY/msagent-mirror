#!/usr/bin/env python3
# -------------------------------------------------------------------------
# This file is part of the MindStudio project.
# Copyright (c) 2026 Huawei Technologies Co.,Ltd.
#
# MindStudio is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#
#          http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
# See the Mulan PSL v2 for more details.
# -------------------------------------------------------------------------

"""Export one completed Harbor job into the compact msagent eval layout."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


def main() -> int:
    args = _parse_args()
    job_dir = args.harbor_job_dir.resolve()
    output_dir = args.output_dir.resolve()
    if not job_dir.is_dir():
        raise SystemExit(f"Harbor job directory does not exist: {job_dir}")
    if output_dir.exists():
        raise SystemExit(f"Evaluation output directory already exists: {output_dir}")

    job_result = _read_json(job_dir / "result.json")
    trials = _load_trials(job_dir)
    if not trials:
        raise SystemExit(f"No completed trial result found in: {job_dir}")

    output_dir.mkdir(parents=True)
    task_summaries: list[dict[str, Any]] = []
    try:
        tasks_dir = output_dir / "tasks"
        tasks_dir.mkdir()
        for trial_dir, trial_result in trials:
            task_summaries.append(_export_trial(tasks_dir, trial_dir, trial_result))

        run_status = _job_status(job_result)
        manifest = _build_manifest(args, job_dir, job_result, task_summaries, run_status)
        _write_json(output_dir / "manifest.json", manifest)
        summary = _build_summary(manifest, task_summaries, run_status)
        _write_json(output_dir / "summary.json", summary)
        (output_dir / "README.md").write_text(_build_readme(manifest, task_summaries, run_status), encoding="utf-8")
    except Exception:
        shutil.rmtree(output_dir)
        raise

    print(output_dir)
    return 0 if all(task["status"] == "completed" for task in task_summaries) else 1


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export a Harbor job to compact, task-oriented evaluation artifacts.")
    parser.add_argument("--harbor-job-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--wheel", type=Path, default=None, help="msagent wheel path (optional for non-msagent agents)")
    parser.add_argument("--image", required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--base-url", default="")
    parser.add_argument("--python-bin", default=None, help="Python binary (optional for non-msagent agents)")
    parser.add_argument("--adapter-dir", type=Path, required=True)
    parser.add_argument("--harbor-bin", default="harbor")
    parser.add_argument("--agent-name", default="msagent", help="Agent name for manifest and README labeling")
    return parser.parse_args()


def _load_trials(job_dir: Path) -> list[tuple[Path, dict[str, Any]]]:
    trials: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(job_dir.iterdir()):
        result_path = path / "result.json"
        if path.is_dir() and result_path.is_file():
            trials.append((path, _read_json(result_path)))
    return trials


def _export_trial(tasks_dir: Path, trial_dir: Path, trial_result: dict[str, Any]) -> dict[str, Any]:
    task_id = _task_id(trial_result)
    task_dir = tasks_dir / task_id
    if task_dir.exists():
        raise RuntimeError(
            f"More than one attempt exists for task '{task_id}'. This export layout requires Harbor --n-attempts 1."
        )
    task_dir.mkdir()

    artifacts: dict[str, str | None] = {
        "events": _copy_if_present(
            trial_dir / "agent" / "msagent.events.jsonl",
            task_dir / "msagent.events.jsonl",
        ),
        "trajectory": _copy_if_present(trial_dir / "agent" / "trajectory.json", task_dir / "trajectory.json"),
        "report": _copy_report(trial_dir, task_dir),
    }

    verifier = _build_verifier_result(trial_dir, trial_result)
    _write_json(task_dir / "verifier.json", verifier)
    artifacts["verifier"] = "verifier.json"

    status = _trial_status(trial_result)
    token_usage = _extract_token_usage(trial_dir / "agent" / "trajectory.json")
    return {
        "task_id": task_id,
        "task_name": trial_result.get("task_name"),
        "task_checksum": trial_result.get("task_checksum"),
        "status": status,
        "rewards": (trial_result.get("verifier_result") or {}).get("rewards"),
        "token_usage": token_usage,
        "timing": {
            "started_at": trial_result.get("started_at"),
            "finished_at": trial_result.get("finished_at"),
            "wall_duration_sec": _duration_sec(trial_result.get("started_at"), trial_result.get("finished_at")),
            "agent_duration_sec": _duration_from_phase(trial_result.get("agent_execution")),
        },
        "exception": trial_result.get("exception_info"),
        "artifacts": artifacts,
        "path": f"tasks/{task_id}",
    }


def _copy_if_present(source: Path, target: Path) -> str | None:
    if not source.is_file():
        return None
    shutil.copy2(source, target)
    return target.name


def _extract_token_usage(trajectory_path: Path) -> dict[str, Any] | None:
    """Extract cumulative token counts from an ATIF trajectory's final_metrics."""
    if not trajectory_path.is_file():
        return None
    try:
        trajectory = _read_json(trajectory_path)
    except RuntimeError:
        return None
    metrics = trajectory.get("final_metrics") or {}
    if not metrics:
        return None
    return {
        "total_prompt_tokens": metrics.get("total_prompt_tokens"),
        "total_completion_tokens": metrics.get("total_completion_tokens"),
        "total_cost_usd": metrics.get("total_cost_usd"),
        "total_steps": metrics.get("total_steps"),
    }


def _copy_report(trial_dir: Path, task_dir: Path) -> str | None:
    source = trial_dir / "agent" / "report.json"
    target = task_dir / "report.json"
    if source.is_file():
        shutil.copy2(source, target)
        return target.name

    # Compatibility path for jobs created before the adapter wrote report.json.
    trajectory_path = trial_dir / "agent" / "trajectory.json"
    if not trajectory_path.is_file():
        return None
    trajectory = _read_json(trajectory_path)
    for step in reversed(trajectory.get("steps", [])):
        if not isinstance(step, dict) or step.get("extra", {}).get("kind") != "final_report":
            continue
        message = step.get("message")
        prefix = "[final report]\n"
        if isinstance(message, str) and message.startswith(prefix):
            target.write_text(message[len(prefix) :], encoding="utf-8")
            return target.name
    return None


def _build_verifier_result(trial_dir: Path, trial_result: dict[str, Any]) -> dict[str, Any]:
    verifier_dir = trial_dir / "verifier"
    return {
        "schema_version": "msagent-eval-verifier-v1",
        "status": _verifier_status(trial_result),
        "result": trial_result.get("verifier_result"),
        "reward_file": _read_optional_json(verifier_dir / "reward.json"),
        "detail": _read_optional_json(verifier_dir / "reward.detail.json"),
        "exception": _verifier_exception(trial_result),
    }


def _build_manifest(
    args: argparse.Namespace,
    job_dir: Path,
    job_result: dict[str, Any],
    tasks: list[dict[str, Any]],
    run_status: str,
) -> dict[str, Any]:
    dataset = args.dataset.resolve()
    adapter_dir = args.adapter_dir.resolve()
    agent_section: dict[str, Any] = {"python_bin": args.python_bin}
    if args.wheel:
        wheel = args.wheel.resolve()
        agent_section["wheel"] = {
            "path": str(wheel),
            "filename": wheel.name,
            "sha256": _file_sha256(wheel),
        }
    return {
        "schema_version": "msagent-eval-manifest-v1",
        "run_id": job_dir.name,
        "status": run_status,
        "started_at": job_result.get("started_at"),
        "finished_at": job_result.get("finished_at"),
        "harbor": {
            "version": _command_output([args.harbor_bin, "--version"]),
            "job_id": job_result.get("id"),
        },
        "adapter": {
            "path": str(adapter_dir),
            "sha256": _tree_sha256(adapter_dir),
        },
        "dataset": {
            "path": str(dataset),
            "git_commit": _git_commit(dataset),
        },
        "agent": agent_section,
        "agent_name": args.agent_name,
        "environment": {"image": _docker_image_identity(args.image)},
        "model": {
            "provider": args.provider,
            "name": args.model,
            "base_url": args.base_url or None,
            "api_key_env": _api_key_env(args.provider),
        },
        "tasks": tasks,
    }


def _build_summary(manifest: dict[str, Any], tasks: list[dict[str, Any]], run_status: str) -> dict[str, Any]:
    rewards = [
        value
        for task in tasks
        for value in (task.get("rewards") or {}).values()
        if isinstance(value, int | float) and not isinstance(value, bool)
    ]
    token_entries = [task["token_usage"] for task in tasks if task.get("token_usage")]
    aggregate: dict[str, Any] = {
        "n_tasks": len(tasks),
        "n_completed": sum(task["status"] == "completed" for task in tasks),
        "n_errored": sum(task["status"] == "errored" for task in tasks),
        "mean_reward": sum(rewards) / len(rewards) if rewards else None,
    }
    if token_entries:
        aggregate["total_prompt_tokens"] = sum((t.get("total_prompt_tokens") or 0) for t in token_entries) or None
        aggregate["total_completion_tokens"] = (
            sum((t.get("total_completion_tokens") or 0) for t in token_entries) or None
        )
        costs = [t.get("total_cost_usd") for t in token_entries if t.get("total_cost_usd")]
        aggregate["total_cost_usd"] = sum(costs) if costs else None
    return {
        "schema_version": "msagent-eval-summary-v1",
        "run_id": manifest["run_id"],
        "agent_name": manifest.get("agent_name"),
        "status": run_status,
        "started_at": manifest["started_at"],
        "finished_at": manifest["finished_at"],
        "aggregate": aggregate,
        "tasks": tasks,
    }


def _build_readme(manifest: dict[str, Any], tasks: list[dict[str, Any]], run_status: str) -> str:
    agent_name = manifest.get("agent_name") or "msagent"
    lines = [
        f"# {agent_name} Evaluation",
        "",
        f"- Run ID: `{manifest['run_id']}`",
        f"- Status: `{run_status}`",
        f"- Model: `{manifest['model']['name']}` ({manifest['model']['provider']})",
    ]
    agent_section = manifest.get("agent", {})
    wheel_info = agent_section.get("wheel", {})
    if wheel_info:
        lines.append(f"- Wheel: `{wheel_info.get('filename')}`")
    lines.extend(
        [
            f"- Image: `{manifest['environment']['image']['reference']}`",
            "",
            "| Task | Status | Reward | Tokens (in/out) | Agent Time | Artifacts |",
            "|---|---|---:|---|---:|---|",
        ]
    )
    for task in tasks:
        rewards = task.get("rewards") or {}
        reward = ", ".join(f"{key}={value}" for key, value in rewards.items()) or "-"
        tu = task.get("token_usage") or {}
        tokens = ""
        if tu:
            p = tu.get("total_prompt_tokens") or 0
            c = tu.get("total_completion_tokens") or 0
            tokens = f"{p}/{c}"
        duration = (task.get("timing") or {}).get("agent_duration_sec")
        duration_text = f"{duration:.3f}s" if isinstance(duration, float) else "-"
        path = task["path"]
        artifact_links = (
            ("report", "report", "report.json"),
            ("events", "events", "msagent.events.jsonl"),
            ("ATIF", "trajectory", "trajectory.json"),
            ("verifier", "verifier", "verifier.json"),
        )
        artifacts = " ".join(
            f"[{label}]({path}/{filename})"
            for label, key, filename in artifact_links
            if task.get("artifacts", {}).get(key)
        )
        lines.append(f"| {task['task_id']} | {task['status']} | {reward} | {tokens} | {duration_text} | {artifacts} |")
    lines.extend(
        [
            "",
            "`summary.json` is the machine-readable task index. `manifest.json` "
            "contains the sanitized reproduction identity for this run.",
            "",
        ]
    )
    return "\n".join(lines)


def _task_id(trial_result: dict[str, Any]) -> str:
    task = trial_result.get("task_id") or {}
    path = task.get("path") if isinstance(task, dict) else None
    if isinstance(path, str) and path:
        return Path(path).name
    task_name = str(trial_result.get("task_name") or "unknown-task")
    return task_name.replace("/", "-")


def _trial_status(result: dict[str, Any]) -> str:
    if result.get("exception_info") is not None:
        return "errored"
    if result.get("verifier_result") is not None:
        return "completed"
    if result.get("finished_at") is not None:
        return "completed_without_verifier"
    return "incomplete"


def _verifier_status(result: dict[str, Any]) -> str:
    if result.get("verifier_result") is not None:
        return "completed"
    exception = result.get("exception_info")
    if isinstance(exception, dict) and result.get("verifier") is not None:
        return "errored"
    return "not_run"


def _verifier_exception(result: dict[str, Any]) -> dict[str, Any] | None:
    exception = result.get("exception_info")
    return exception if result.get("verifier") is not None and isinstance(exception, dict) else None


def _job_status(result: dict[str, Any]) -> str:
    stats = result.get("stats") or {}
    if stats.get("n_errored_trials", 0):
        return "completed_with_errors"
    return "completed" if result.get("finished_at") else "incomplete"


def _duration_from_phase(phase: Any) -> float | None:
    if not isinstance(phase, dict):
        return None
    return _duration_sec(phase.get("started_at"), phase.get("finished_at"))


def _duration_sec(started_at: Any, finished_at: Any) -> float | None:
    if not isinstance(started_at, str) or not isinstance(finished_at, str):
        return None
    try:
        started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        finished = datetime.fromisoformat(finished_at.replace("Z", "+00:00"))
    except ValueError:
        return None
    return round((finished - started).total_seconds(), 3)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Could not read JSON file {path}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"Expected a JSON object in {path}")
    return value


def _read_optional_json(path: Path) -> dict[str, Any] | None:
    return _read_json(path) if path.is_file() else None


def _write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if "__pycache__" in path.parts:
            continue
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(_file_sha256(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _command_output(command: list[str]) -> str | None:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def _git_commit(path: Path) -> str | None:
    return _command_output(["git", "-C", str(path), "rev-parse", "HEAD"])


def _docker_image_identity(image: str) -> dict[str, Any]:
    fallback = {"reference": image, "id": None, "repo_digests": []}
    try:
        raw = subprocess.check_output(["docker", "image", "inspect", image], text=True, stderr=subprocess.DEVNULL)
        details = json.loads(raw)[0]
    except (OSError, subprocess.CalledProcessError, IndexError, json.JSONDecodeError):
        return fallback
    return {
        "reference": image,
        "id": details.get("Id"),
        "repo_digests": details.get("RepoDigests") or [],
        "architecture": details.get("Architecture"),
        "os": details.get("Os"),
    }


def _api_key_env(provider: str) -> str | None:
    return {
        "openai": "OPENAI_API_KEY",
        "anthropic": "ANTHROPIC_API_KEY",
        "google": "GOOGLE_API_KEY",
    }.get(provider.lower())


if __name__ == "__main__":
    sys.exit(main())
