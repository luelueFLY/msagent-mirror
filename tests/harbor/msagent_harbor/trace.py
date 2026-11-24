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

"""Conversion from msagent CLI JSONL events to Harbor ATIF trajectories."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from harbor.models.trajectories import (
    FinalMetrics,
    Observation,
    ObservationResult,
    Step,
    ToolCall,
)


def read_events(path: Path) -> list[dict[str, Any]]:
    """Read valid JSON-object events while keeping a partial trace usable."""
    if not path.is_file():
        return []

    events: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def events_to_steps(
    events: list[dict[str, Any]],
    model_name: str | None,
    initial_prompt: str | None = None,
) -> list[Step]:
    """Convert the stable public CLI trace fields into ATIF v1.7 steps."""
    steps: list[Step] = []
    tool_call_steps: dict[str, Step] = {}
    step_id = 1

    def append(**kwargs: Any) -> None:
        nonlocal step_id
        steps.append(Step(step_id=step_id, **kwargs))
        step_id += 1

    if initial_prompt:
        append(source="user", message=initial_prompt)

    for event in events:
        event_type = str(event.get("type") or "")
        timestamp = _timestamp(event.get("timestamp"))

        if event_type == "session_started":
            append(timestamp=timestamp, source="system", message="msagent session started")
        elif event_type == "assistant_message":
            content = event.get("content")
            if isinstance(content, str) and content.strip():
                append(
                    timestamp=timestamp,
                    source="agent",
                    message=content,
                    model_name=model_name,
                    llm_call_count=1,
                )
        elif event_type == "tool_call":
            call_id = str(event.get("item_id") or f"tool-call-{step_id}")
            arguments = event.get("input")
            step = Step(
                step_id=step_id,
                timestamp=timestamp,
                source="agent",
                message="",
                llm_call_count=0,
                tool_calls=[
                    ToolCall(
                        tool_call_id=call_id,
                        function_name=str(event.get("tool") or "unknown"),
                        arguments=arguments if isinstance(arguments, dict) else {},
                    )
                ],
            )
            steps.append(step)
            tool_call_steps[call_id] = step
            step_id += 1
        elif event_type == "tool_result":
            output = event.get("output")
            content, extra = _tool_result_content(output)
            call_id = _nonempty_str(event.get("item_id"))
            result = ObservationResult(
                source_call_id=call_id,
                content=content,
                extra=extra or None,
            )
            target = tool_call_steps.get(call_id) if call_id else None
            if target is not None:
                if target.observation is None:
                    target.observation = Observation(results=[result])
                else:
                    target.observation.results.append(result)
            else:
                # Preserve a malformed or legacy orphan result without claiming
                # it belongs to an unrelated tool call.
                append(
                    timestamp=timestamp,
                    source="system",
                    message="",
                    observation=Observation(results=[result.model_copy(update={"source_call_id": None})]),
                    extra={"orphan_tool_result_id": call_id} if call_id else None,
                )
        elif event_type == "error":
            message = _nonempty_str(event.get("message")) or "msagent reported an error"
            append(
                timestamp=timestamp,
                source="system",
                message=message,
                extra={"error_type": event.get("error_type")},
            )
        elif event_type == "session_finished":
            append(timestamp=timestamp, source="system", message="msagent session finished")

    return steps


def final_metrics(events: list[dict[str, Any]], duration_sec: float, total_steps: int) -> FinalMetrics:
    """Extract cumulative token usage emitted by the msagent CLI recorder."""
    usage: dict[str, Any] = {}
    for event in reversed(events):
        if event.get("type") == "session_finished" and isinstance(event.get("token_usage"), dict):
            usage = event["token_usage"]
            break
        if event.get("type") == "token_usage" and isinstance(event.get("cumulative"), dict):
            usage = event["cumulative"]
            break

    return FinalMetrics(
        total_prompt_tokens=_as_positive_int(usage.get("input_tokens")),
        total_completion_tokens=_as_positive_int(usage.get("output_tokens")),
        total_steps=total_steps,
        extra={
            "total_tokens": _as_positive_int(usage.get("total_tokens")),
            "token_usage_source": usage.get("source"),
            "duration_sec": round(duration_sec, 3),
        },
    )


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _tool_result_content(output: Any) -> tuple[str, dict[str, Any]]:
    if isinstance(output, dict):
        content = output.get("content")
        if not isinstance(content, str):
            content = json.dumps(output, ensure_ascii=False, default=str)
        extra = {key: output[key] for key in ("is_error", "content_truncated") if key in output}
        return content[:20_000], extra
    return str(output or "")[:20_000], {}


def _timestamp(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _nonempty_str(value: Any) -> str | None:
    return str(value) if value is not None and str(value) else None


def _as_positive_int(value: Any) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None
