#!/usr/bin/python3
# -*- coding: utf-8 -*-
# -------------------------------------------------------------------------
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# This file is part of the MindStudio project.
#
# MindStudio is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#
#    http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
# See the Mulan PSL v2 for more details.
# -------------------------------------------------------------------------

"""Model retry middleware that logs retries and notifies the TUI."""

from __future__ import annotations

import asyncio
import logging
import time
from inspect import iscoroutine
from typing import TYPE_CHECKING, Any, Callable
from uuid import uuid4

from langchain.agents.middleware import ModelRetryMiddleware
from langchain.agents.middleware._retry import calculate_delay, should_retry_exception

from msagent.agents.context import RetryNotice

if TYPE_CHECKING:
    from collections.abc import Awaitable
    from langchain.agents.middleware.types import ContextT, ModelRequest, ModelResponse, ResponseT
    from langchain_core.messages import AIMessage

logger = logging.getLogger(__name__)


class LoggingModelRetryMiddleware(ModelRetryMiddleware):
    """`ModelRetryMiddleware` that logs every retry attempt and notifies the TUI.

    On each retryable failure it emits a `WARNING` log and forwards a
    `RetryNotice` to the runtime context TUI handler (when registered) so
    users can see retries directly in the interactive session.
    """

    def _log_retry(self, attempt: int, exc: Exception, delay: float) -> None:
        logger.warning(
            "model call failed with %s: %s; retrying %d/%d in %.2fs",
            type(exc).__name__,
            exc,
            attempt + 1,
            self.max_retries,
            delay,
        )

    def _emit_retry_notice(self, request: Any, attempt: int, delay: float) -> None:
        """Forward the retry to the runtime context TUI handler when available."""
        context = getattr(getattr(request, "runtime", None), "context", None)
        notice_handler = getattr(context, "retry_notice_handler", None)
        if notice_handler is None:
            return
        notice = RetryNotice(
            notice_id=uuid4().hex,
            scope="llm",
            attempt=attempt + 1,
            max_retries=self.max_retries,
            delay=delay,
            phase="scheduled",
        )
        try:
            result = notice_handler(notice)
        except Exception:
            logger.debug("retry notice handler raised; ignored.", exc_info=True)
            return
        if iscoroutine(result):
            try:
                asyncio.get_running_loop().create_task(result)
            except RuntimeError:
                result.close()

    def wrap_model_call(
        self,
        request: ModelRequest[ContextT],
        handler: Callable[[ModelRequest[ContextT]], ModelResponse[ResponseT]],
    ) -> ModelResponse[ResponseT] | AIMessage:
        for attempt in range(self.max_retries + 1):
            try:
                return handler(request)
            except Exception as exc:
                attempts_made = attempt + 1
                if not should_retry_exception(exc, self.retry_on):
                    return self._handle_failure(exc, attempts_made)
                if attempt < self.max_retries:
                    delay = calculate_delay(
                        attempt,
                        backoff_factor=self.backoff_factor,
                        initial_delay=self.initial_delay,
                        max_delay=self.max_delay,
                        jitter=self.jitter,
                    )
                    self._log_retry(attempt, exc, delay)
                    self._emit_retry_notice(request, attempt, delay)
                    if delay > 0:
                        time.sleep(delay)
                else:
                    return self._handle_failure(exc, attempts_made)
        msg = "Unexpected: retry loop completed without returning"
        raise RuntimeError(msg)

    async def awrap_model_call(
        self,
        request: ModelRequest[ContextT],
        handler: Callable[[ModelRequest[ContextT]], Awaitable[ModelResponse[ResponseT]]],
    ) -> ModelResponse[ResponseT] | AIMessage:
        for attempt in range(self.max_retries + 1):
            try:
                return await handler(request)
            except Exception as exc:
                attempts_made = attempt + 1
                if not should_retry_exception(exc, self.retry_on):
                    return self._handle_failure(exc, attempts_made)
                if attempt < self.max_retries:
                    delay = calculate_delay(
                        attempt,
                        backoff_factor=self.backoff_factor,
                        initial_delay=self.initial_delay,
                        max_delay=self.max_delay,
                        jitter=self.jitter,
                    )
                    self._log_retry(attempt, exc, delay)
                    self._emit_retry_notice(request, attempt, delay)
                    if delay > 0:
                        await asyncio.sleep(delay)
                else:
                    return self._handle_failure(exc, attempts_made)
        msg = "Unexpected: retry loop completed without returning"
        raise RuntimeError(msg)
