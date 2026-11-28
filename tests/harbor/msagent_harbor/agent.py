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

"""Harbor agent adapter that executes a wheel-installed ``msagent`` CLI."""

from __future__ import annotations

import json
import shlex
import time
from pathlib import Path, PurePosixPath
from typing import Any

from harbor.agents.installed.base import (
    BaseInstalledAgent,
    CliFlag,
    NonZeroAgentExitCodeError,
)
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trajectories import Agent, Step, Trajectory
from harbor.utils.trajectory_utils import format_trajectory_json

from .trace import events_to_steps, final_metrics, read_events, utc_now


class MsagentHarborAgent(BaseInstalledAgent):
    """Run a local wheel-installed ``msagent`` CLI in the task container.

    ``msagent_wheel`` is a host path supplied through Harbor's ``--agent-kwarg``.
    It is uploaded during setup, so each fresh trial tests exactly that wheel.
    """

    SUPPORTS_ATIF = True
    CLI_FLAGS = [
        CliFlag(
            "msagent_agent",
            cli="--agent",
            type="str",
            default="Profiler",
            env_fallback="MSAGENT_AGENT",
        ),
        CliFlag(
            "approval_mode",
            cli="--approval-mode",
            type="str",
            default="aggressive",
            choices=["semi-active", "active", "aggressive"],
            env_fallback="MSAGENT_APPROVAL_MODE",
        ),
        CliFlag(
            "execute_approval_mode",
            cli="--execute-approval-mode",
            type="str",
            default="auto",
            choices=["manual", "auto"],
            env_fallback="MSAGENT_EXECUTE_APPROVAL_MODE",
        ),
    ]

    _TRACE_FILENAME = "msagent.events.jsonl"
    _WORKSPACE = "/workspace"
    _WHEEL_DIRECTORY = PurePosixPath("/installed-agent")

    def __init__(
        self,
        logs_dir: Path,
        msagent_wheel: str | Path | None = None,
        msagent_python: str = "python",
        **kwargs: object,
    ) -> None:
        self._msagent_wheel = Path(msagent_wheel).expanduser().resolve() if msagent_wheel else None
        if not msagent_python or not msagent_python.strip():
            raise ValueError("msagent_python must name a Python executable")
        self._msagent_python = msagent_python.strip()
        self._python_scripts_dir: str | None = None
        super().__init__(logs_dir=logs_dir, **kwargs)

    @staticmethod
    def name() -> str:
        return "msagent-harbor"

    def get_version_command(self) -> str | None:
        return shlex.join(self._msagent_command("--version"))

    async def install(self, environment: BaseEnvironment) -> None:
        wheel = self._msagent_wheel
        if wheel is None:
            raise ValueError("msagent_wheel must be supplied through --agent-kwarg")
        if wheel.suffix != ".whl" or not wheel.is_file():
            raise ValueError(f"msagent_wheel must be an existing .whl file: {wheel}")

        target = self._WHEEL_DIRECTORY / wheel.name
        await environment.upload_file(source_path=wheel, target_path=str(target))
        await self.exec_as_root(
            environment,
            command=shlex.join(
                [
                    self._msagent_python,
                    "-m",
                    "pip",
                    "install",
                    "--no-cache-dir",
                    "--force-reinstall",
                    str(target),
                ]
            ),
            env={
                "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                **self._pip_environment(),
            },
        )
        result = await self.exec_as_root(
            environment,
            command=shlex.join(
                [
                    self._msagent_python,
                    "-c",
                    "import sysconfig; print(sysconfig.get_path('scripts'))",
                ]
            ),
        )
        scripts_dir = (result.stdout or "").strip()
        if not scripts_dir.startswith("/"):
            raise RuntimeError("could not determine the selected Python's scripts directory")
        self._python_scripts_dir = scripts_dir

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        provider, model, api_key_name = self._llm_settings()
        agent_dir = self.environment_logs_dir
        trace_path = agent_dir / self._TRACE_FILENAME
        msagent_home = agent_dir / "msagent-home"
        runtime_env = {
            "MSAGENT_HOME": str(msagent_home),
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "TERM": "dumb",
            "PYTHONUNBUFFERED": "1",
            # The CLI falls back to terminal detection for one-shot runs; make
            # the eval path explicit so approval prompts never wait on input.
            "MSAGENT_NON_INTERACTIVE": "1",
            **self._runtime_environment(api_key_name),
        }

        await self._require_success(
            environment,
            command=(
                f"mkdir -p {shlex.quote(str(agent_dir))} "
                f"{shlex.quote(str(msagent_home))} {shlex.quote(self._WORKSPACE)} "
                f"&& if [ -d /input_data ] && [ ! -e "
                f"{shlex.quote(str(PurePosixPath(self._WORKSPACE) / 'input_data'))} ]; "
                f"then ln -s /input_data "
                f"{shlex.quote(str(PurePosixPath(self._WORKSPACE) / 'input_data'))}; fi"
            ),
            env=runtime_env,
            stage="prepare msagent runtime and task input",
        )
        await self._configure_llm(
            environment,
            provider=provider,
            model=model,
            env=runtime_env,
        )
        await self._seed_approval_rules(environment, msagent_home, runtime_env)

        prompt = _build_prompt(instruction)
        command = shlex.join(
            self._msagent_command(
                "--working-dir",
                self._WORKSPACE,
                "--agent",
                self._resolved_flags["msagent_agent"],
                "--approval-mode",
                self._resolved_flags["approval_mode"],
                "--execute-approval-mode",
                self._resolved_flags["execute_approval_mode"],
                "--model",
                "default",
                "--trace-jsonl",
                str(trace_path),
                prompt,
            )
        )
        started = time.monotonic()
        result = await environment.exec(command=self._with_python_path(command), env=runtime_env)
        duration_sec = time.monotonic() - started
        if result.return_code != 0:
            detail = (result.stderr or result.stdout or "no CLI output")[-2_000:]
            raise NonZeroAgentExitCodeError(
                f"msagent exited with {result.return_code}; required key: {api_key_name}; {detail}"
            )

        events = read_events(self.logs_dir / self._TRACE_FILENAME)
        if not events:
            raise RuntimeError("msagent exited successfully but emitted no JSONL trace")
        steps = events_to_steps(
            events,
            model_name=self.model_name or model,
            initial_prompt=prompt,
        )
        report = await _read_report(environment, self._WORKSPACE)
        report_source = "file"
        report_path = self.logs_dir / "report.json"
        if report is None:
            # The model sometimes delivers the report as its final chat message
            # instead of writing /workspace/report.json. Promote that message to
            # the report file so the verifier still scores the run; the source
            # is recorded in the metadata so infra runs stay honest.
            report = _final_message_from_events(events)
            if report is None:
                raise RuntimeError(
                    "msagent exited successfully but wrote no /workspace/report.json "
                    "and emitted no final assistant message"
                )
            report_source = "final-message-fallback"
            report_path.write_text(report, encoding="utf-8")
            await environment.upload_file(
                source_path=str(report_path),
                target_path=str(PurePosixPath(self._WORKSPACE) / "report.json"),
            )
        else:
            report_path.write_text(report, encoding="utf-8")
        steps.append(
            Step(
                step_id=len(steps) + 1,
                timestamp=utc_now(),
                source="agent",
                message="[final report]\n" + report[:200_000],
                llm_call_count=0,
                extra={"kind": "final_report"},
            )
        )

        metrics = final_metrics(events, duration_sec, len(steps))
        context.n_input_tokens = metrics.total_prompt_tokens
        context.n_output_tokens = metrics.total_completion_tokens
        context.metadata = {
            **(context.metadata or {}),
            "trace_path": self._TRACE_FILENAME,
            "trajectory_path": "trajectory.json",
            "report_path": "report.json",
            "report_source": report_source,
            "trace_event_count": len(events),
            "duration_sec": round(duration_sec, 3),
        }

        trajectory = Trajectory(
            agent=Agent(
                name=self.name(),
                version=self.version() or "unknown",
                model_name=self.model_name or model,
            ),
            steps=steps,
            final_metrics=metrics,
        )
        trajectory_path = self.logs_dir / "trajectory.json"
        trajectory_path.parent.mkdir(parents=True, exist_ok=True)
        trajectory_path.write_text(
            format_trajectory_json(trajectory.model_dump(exclude_none=True)),
            encoding="utf-8",
        )

    def _llm_settings(self) -> tuple[str, str, str]:
        provider = (self._get_env("MSAGENT_LLM_PROVIDER") or "").lower().strip()
        if provider == "gemini":
            provider = "google"
        if provider not in {"openai", "anthropic", "google"}:
            raise ValueError("MSAGENT_LLM_PROVIDER must be one of: openai, anthropic, google")

        model = (self._get_env("MSAGENT_LLM_MODEL") or "").strip()
        if not model:
            raise ValueError("MSAGENT_LLM_MODEL must name the provider model")

        key_name = {
            "openai": "OPENAI_API_KEY",
            "anthropic": "ANTHROPIC_API_KEY",
            "google": "GOOGLE_API_KEY",
        }[provider]
        if not self._get_env(key_name):
            raise ValueError(f"agent environment is missing {key_name}")
        return provider, model, key_name

    async def _configure_llm(
        self,
        environment: BaseEnvironment,
        *,
        provider: str,
        model: str,
        env: dict[str, str],
    ) -> None:
        command = self._msagent_command(
            "config",
            "--working-dir",
            self._WORKSPACE,
            "--llm-provider",
            provider,
            "--llm-model",
            model,
        )
        base_url = (self._get_env("MSAGENT_LLM_BASE_URL") or "").strip()
        if base_url:
            command.extend(["--llm-base-url", base_url])
        await self._require_success(
            environment,
            command=self._with_python_path(shlex.join(command)),
            env=env,
            stage="configure msagent LLM",
        )

    async def _seed_approval_rules(
        self,
        environment: BaseEnvironment,
        msagent_home: Path,
        env: dict[str, str],
    ) -> None:
        """Allow the task data mount and auto-approve shell commands.

        msagent's approval boundary resolves the ``/workspace/input_data``
        symlink to ``/input_data`` and treats that mount as an external
        directory. In the non-interactive eval there is nobody to answer the
        approval prompt, which aborts the trial with ``TypeError``. Seed the
        project approval rules (the ``msagent config`` step above creates the
        project state directory) so ``/input_data`` is allowed and shell
        execution runs in auto mode.
        """
        payload = json.dumps(
            {
                "external_directories": [{"path": "/input_data"}],
                "execute_approval_mode": "auto",
            },
            separators=(",", ":"),
        )
        home = shlex.quote(str(msagent_home))
        command = (
            f"d=$(ls -d {home}/state/projects/*/ 2>/dev/null | head -1); "
            f'[ -n "$d" ] && printf \'%s\\n\' {shlex.quote(payload)} > "$d/config.approval.json"'
        )
        await self._require_success(
            environment,
            command=command,
            env=env,
            stage="seed project approval rules",
        )

    def _msagent_command(self, *arguments: str) -> list[str]:
        """Use the selected interpreter so its installed wheel is unambiguous."""
        return [
            self._msagent_python,
            "-m",
            "msagent.cli.bootstrap.app",
            *arguments,
        ]

    def _runtime_environment(self, api_key_name: str) -> dict[str, str]:
        """Pass provider settings to the container without persisting secrets.

        The runner keeps these values in its own process environment rather
        than passing them with Harbor ``--ae``, whose values are recorded in
        the job configuration. Container commands receive only this temporary
        environment mapping.
        """
        names = (
            "MSAGENT_LLM_PROVIDER",
            "MSAGENT_LLM_MODEL",
            "MSAGENT_LLM_BASE_URL",
            api_key_name,
        )
        return {name: value for name in names if (value := self._get_env(name)) is not None and value != ""}

    def _pip_environment(self) -> dict[str, str]:
        return {
            name: value
            for name in (
                "PIP_INDEX_URL",
                "PIP_EXTRA_INDEX_URL",
                "PIP_TRUSTED_HOST",
            )
            if (value := self._get_env(name)) is not None and value != ""
        }

    def _with_python_path(self, command: str) -> str:
        if self._python_scripts_dir is None:
            return command
        return f"PATH={shlex.quote(self._python_scripts_dir)}:$PATH {command}"

    async def _require_success(
        self,
        environment: BaseEnvironment,
        *,
        command: str,
        env: dict[str, str],
        stage: str,
    ) -> None:
        result = await environment.exec(command=command, env=env)
        if result.return_code != 0:
            detail = (result.stderr or result.stdout or "no command output")[-2_000:]
            raise RuntimeError(f"failed to {stage}: {detail}")


def _build_prompt(instruction: str) -> str:
    return (
        f"{instruction}\n\n"
        "Deliverable: write your complete final analysis to /workspace/report.json "
        "using the write_file tool as your FINAL action, then reply with exactly "
        "one line: done"
    )


def _final_message_from_events(events: list[dict[str, Any]]) -> str | None:
    """Return the last non-empty assistant message (the agent's deliverable)."""
    for event in reversed(events):
        if event.get("type") != "assistant_message":
            continue
        content = event.get("content")
        if isinstance(content, str) and content.strip():
            return content
    return None


async def _read_report(environment: BaseEnvironment, workspace: str) -> str | None:
    result = await environment.exec(command=f"cat {shlex.quote(str(PurePosixPath(workspace) / 'report.json'))}")
    return result.stdout if result.return_code == 0 else None
