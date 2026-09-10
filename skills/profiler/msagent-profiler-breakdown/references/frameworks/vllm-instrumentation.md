# vLLM / vLLM-Ascend 打点清单（record\_function\_or\_nullcontext · MSTX）

> 消费 skill：`msagent-profiler-breakdown`（decompose.py，阶段归因 + 单次执行边界）· `layer-decompose`（layer\_map）
> 性质：框架打点**事实清单**（非规则），供三处 `frameworks/vllm.md` 引用；引擎按 scope 名做边界/阶段匹配。
> 来源：代码静态梳理（vLLM 主仓库 + vLLM-Ascend）。**不含** MS Service Profiler、**不含**可观测性/OpenTelemetry traces 打点。
> 范围：仅 `record_function_or_nullcontext` 与 `MSTX`。`torch.profiler.record_function`（CUDA graph capture）与 `annotate_profile`（execute\_ 注解）属于另两条通路，见 §4。
> 互补资源：PyTorch Profiler 采集数据/字段（`torch.profiler` vs `torch_npu.profiler`）与 MSTX 落地口径，见同目录 `vllm-profiler-data.md`。

***

## 0. 机制与开关（先决事实）

| 项        | 说明                                                                                                                                                                                       |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 唯一实现     | vLLM `vllm/v1/utils.py` 的 `record_function_or_nullcontext(name)`；vLLM-Ascend 直接 `import` 复用，不另造                                                                                          |
| 开关       | `VLLM_CUSTOM_SCOPES_FOR_PROFILING=1` → `torch.autograd.profiler.record_function`；`VLLM_NVTX_SCOPES_FOR_PROFILING=1` → `nvtx.annotate`；全不设 → `nullcontext`（零开销不打点）                        |
| 字段       | 打点**只有** **`name`（scope 字符串）一个字段**，无 attributes；落地 DB 为 `PYTORCH_API` 表事件（`name` 经 `STRING_IDS` 反查）                                                                                      |
| shape 线索 | vLLM GPU 走 `torch.profiler.record_shapes` 才有 `Input Dims`；vLLM-Ascend 的 `torch_npu.profiler` **无 record\_shapes**，但 shape 仍可从 DB `PYTORCH_API.inputShapes/inputDtypes`（`STRING_IDS` 反查）取 |
| MSTX     | vLLM-Ascend `_ExperimentalConfig(msprof_tx=False)` 显式关闭；`PYTORCH_API.type` 枚举含 `mstx`，仅 `msprof_tx=True` 时才产出，默认无 mstx 记录                                                                |

***

## 1. vLLM 打点全清单（19 处）

### 1.1 gpu\_model\_runner.py —— 引擎主流程（10，一次 step 的时序骨架）

| scope name                                      | 位置                                        | 语义                    | 拆解维度             |
| ----------------------------------------------- | ----------------------------------------- | --------------------- | ---------------- |
| `gpu_model_runner: preprocess`                  | `vllm/v1/worker/gpu_model_runner.py:4309` | 状态更新 + 输入准备           | step 内阶段         |
| `gpu_model_runner: forward`                     | `vllm/v1/worker/gpu_model_runner.py:4544` | **模型前向**（最重，一次执行本体）   | **step 边界 A 锚点** |
| `gpu_model_runner: postprocess`                 | `vllm/v1/worker/gpu_model_runner.py:4558` | hidden→logits / PP 广播 | step 内阶段         |
| `gpu_model_runner: sample`                      | `vllm/v1/worker/gpu_model_runner.py:4688` | 采样                    | stage：sample     |
| `gpu_model_runner: draft`                       | `vllm/v1/worker/gpu_model_runner.py:4713` | 投机 drafter 前向         | 投机推理             |
| `gpu_model_runner: bookkeep`                    | `vllm/v1/worker/gpu_model_runner.py:4816` | bookkeeping sync      | step 内阶段         |
| `gpu_model_runner: eplb`                        | `vllm/v1/worker/gpu_model_runner.py:4860` | EPLB 负载均衡             | 通信/负载            |
| `gpu_model_runner: ModelRunnerOutput`           | `vllm/v1/worker/gpu_model_runner.py:4867` | 组装输出                  | step 内阶段         |
| `gpu_model_runner: AsyncGPUModelRunnerOutput`   | `vllm/v1/worker/gpu_model_runner.py:4895` | 异步输出快照                | step 内阶段         |
| `gpu_model_runner: set_async_sampled_token_ids` | `vllm/v1/worker/gpu_model_runner.py:4924` | 异步 token 回填           | step 内阶段         |

### 1.2 llm\_engine.py —— 引擎层（4）

| scope name                         | 位置                                 |
| ---------------------------------- | ---------------------------------- |
| `llm_engine step: get_output`      | `vllm/v1/engine/llm_engine.py:311` |
| `llm_engine step: process_outputs` | `vllm/v1/engine/llm_engine.py:315` |
| `llm_engine step: abort_requests`  | `vllm/v1/engine/llm_engine.py:327` |
| `llm_engine step: record_stats`    | `vllm/v1/engine/llm_engine.py:331` |

### 1.3 scheduler.py —— 调度层（4，CPU 侧）

| scope name                               | 位置                                     |
| ---------------------------------------- | -------------------------------------- |
| `schedule: allocate_slots`               | `vllm/v1/core/sched/scheduler.py:701`  |
| `schedule: get_num_common_prefix_blocks` | `vllm/v1/core/sched/scheduler.py:1281` |
| `schedule: make_cached_request_data`     | `vllm/v1/core/sched/scheduler.py:1313` |
| `schedule: update_after_schedule`        | `vllm/v1/core/sched/scheduler.py:1429` |

### 1.4 spec\_decode —— 投机推理（1）

| scope name                   | 位置                                              | 语义            |
| ---------------------------- | ----------------------------------------------- | ------------- |
| `ngram_proposer_gpu: kernel` | `vllm/v1/spec_decode/ngram_proposer_gpu.py:384` | ngram GPU 提议核 |

***

## 2. vLLM-Ascend 打点全清单（26 处）

### 2.1 model\_runner\_v1.py —— 主流程（7）

| scope name           | 位置                                           | 备注                              |
| -------------------- | -------------------------------------------- | ------------------------------- |
| `prepare input`      | `vllm_ascend/worker/model_runner_v1.py:2141` | 对应 vLLM `preprocess`            |
| `forward`            | `vllm_ascend/worker/model_runner_v1.py:2399` | `ExitStack` 形式；**step 边界 A 锚点** |
| `post process`       | `vllm_ascend/worker/model_runner_v1.py:2450` | 对应 vLLM `postprocess`           |
| `sample_token`       | `vllm_ascend/worker/model_runner_v1.py:2570` | 对应 vLLM `sample`                |
| `draft_token`        | `vllm_ascend/worker/model_runner_v1.py:2617` | 早 PP 分支，投机推理                    |
| `draft_token`        | `vllm_ascend/worker/model_runner_v1.py:2636` | 常规分支，投机推理                       |
| `async_state_update` | `vllm_ascend/worker/model_runner_v1.py:2701` | `ExitStack` 形式                  |

### 2.2 EPLB —— 负载均衡（3，Ascend 独有）

| scope name               | 位置                                                         |
| ------------------------ | ---------------------------------------------------------- |
| `EPLB generate p2p task` | `vllm_ascend/eplb/eplb_updator.py:111`                     |
| `EPLB gather moe load`   | `vllm_ascend/eplb/eplb_updator.py:131`                     |
| `EPLB weight D2D wait`   | `vllm_ascend/eplb/core/eplb_device_transfer_loader.py:104` |

### 2.3 schedule: 系列（4 套 scheduler 实现 × 各 4 个 = 16）

四组 scope 名完全一致，分布在 4 套 scheduler：

| scope name                               | patch\_balance\_schedule.py | scheduler\_profiling\_chunk.py | recompute\_scheduler.py | dyntra\_lb\_scheduler.py |
| ---------------------------------------- | --------------------------- | ------------------------------ | ----------------------- | ------------------------ |
| `schedule: allocate_slots`               | `:295`                      | `:353`                         | `:377`                  | `:556`                   |
| `schedule: get_num_common_prefix_blocks` | `:747`                      | `:697`                         | `:940`                  | `:1068`                  |
| `schedule: make_cached_request_data`     | `:770`                      | `:720`                         | `:963`                  | `:1091`                  |
| `schedule: update_after_schedule`        | `:830`                      | `:758`                         | `:1042`                 | `:1194`                  |

- `patch/platform/patch_balance_schedule.py`：对 vLLM 上游 scheduler 的 platform patch（EPLB）。

- `core/scheduler_profiling_chunk.py` / `core/recompute_scheduler.py` / `core/dyntra_lb_scheduler.py`：Ascend 自研 scheduler 变体（profiling-chunk / recompute / 动态负载均衡）。

### 2.4 非打点（勿混入）

- `vllm_ascend/profiling_config.py:112-114` 的 `record_function_or_nullcontext` 是 **MS Service Profiler 的 symbol/handler 配置**，非本清单范围。

***

## 3. MSTX 打点（结论：均无实际采点）

| 仓库          | 结果                                                                           |
| ----------- | ---------------------------------------------------------------------------- |
| vLLM        | 无任何 MSTX（CUDA 无此机制）                                                          |
| vLLM-Ascend | 仅 `profiler/torch_npu_profiler.py:53` 一处 `msprof_tx=False`（显式关闭），无实际 MSTX 采点 |

- 落地含义：默认落盘 `PYTORCH_API` 表中**不会**出现 `type='mstx'` 记录；step 边界改用 `STEP_TIME` 表 / `forward` scope（`record_function`）。

- 若要启用 MSTX 作 step/层边界：把 `msprof_tx` 改为 `True`（或做成配置），重采后 `PYTORCH_API.type='mstx'` 可作精确锚点。

***

## 4. 打点 → 拆解维度映射与关键澄清（纠正既有 profile 的错误假设）

| 拆解目标                         | 可用的真实打点                                                                                                         | 说明                                                                                                                                                                                                                |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **step 边界（boundary A）**      | vLLM `gpu_model_runner: forward`；Ascend `forward`；或 DB `STEP_TIME` 表                                            | 每次模型执行出现一次，span 起始即一次 forward 起点；`STEP_TIME` 为首要来源                                                                                                                                                                |
| **prefill/decode 判别（stage）** | `record_function_or_nullcontext` 内**无 prefill/decode 字样**                                                       | 判别不靠本清单的 scope 名，而靠：① vLLM GPU 的 `annotate_profile` 注解 `execute_context_X_generation_Y`（仅在 `gpu_worker.py`，**Ascend 无**）；② `PYTORCH_API.inputShapes` 的 batch/token 维；③ attention kernel 类型（预填充 vs PagedAttention） |
| **投机推理**                     | vLLM `gpu_model_runner: draft` + `ngram_proposer_gpu: kernel`；Ascend `draft_token`                              | `draft` span 包住 drafter 前向，可单列投机开销                                                                                                                                                                                |
| **层边界（layer）**               | **无默认分层打点**（无 `model.layers.{i}`）                                                                               | 层归属靠 B 策略注入 `record_function`/MSTX、或序列对齐兜底、或 `with_modules`；不可假设已有层打点                                                                                                                                             |
| EPLB / 通信                    | vLLM `gpu_model_runner: eplb`；Ascend `EPLB generate p2p task` / `EPLB gather moe load` / `EPLB weight D2D wait` | 通信在独立 comm stream，归通信子模块，见 `layer-map`                                                                                                                                                                            |
| 调度（CPU 侧）                    | `schedule:*` 系列（vLLM 1 套 + Ascend 4 套）                                                                          | 非 GPU 前向，调度/CPU 开销归因                                                                                                                                                                                              |

### 修正既有 profile 的 3 处错误命名

1. `record_function("step")` → 实际是 `gpu_model_runner: forward`（vLLM）/`forward`（Ascend）；`execute_model` 在 GPU 侧由 `annotate_profile`（`torch.profiler.record_function` 通路）注解，非 `record_function_or_nullcontext`。
2. `record_function("prefill")` / `record_function("decode")` → **代码中不存在**；prefill/decode 判别是 §4 表的②③两条，不可按这两个名字匹配。
3. `model.layers.{i}`（DecoderLayer 层边界）→ **默认不存在**，属 B 策略注入项，不是默认已有打点。

