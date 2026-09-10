# vLLM 框架 Profile —— stage\_taxonomy + boundary

> 消费 skill：`msagent-profiler-breakdown`（decompose.py，阶段归因 + 单次执行边界）
> 承载维度：`stage_taxonomy`（阶段切分差异）+ `boundary`（单次执行边界）+ `parallel_default`（PP 分层映射）
> 范围：推理五 stage（prepare\_input/forward/post\_process/sample\_token/draft\_token）；decode 先行，prefill 待补
> 性质：声明式规则（引擎按场景资源文件读取，不感知框架名；本文件为 vLLM 侧事实/规则说明）
> 互补资源：`vllm-instrumentation.md`（record\_function\_or\_nullcontext scope 清单）、`vllm-profiler-data.md`（PyTorch Profiler 采集数据与字段）

## 1. 阶段清单（推理五 stage）

| stage          | 语义                        | 判别信号（scope 名）   |
| -------------- | ------------------------- | --------------- |
| prepare\_input | 输入准备（token 打包/reshape/拷贝） | `prepare input` |
| forward        | 逐 token 自回归前向（模型主体）       | `forward`       |
| post\_process  | 前向后处理                     | `post process`  |
| sample\_token  | 采样（多为 CPU/轻量 GPU 侧）       | `sample_token`  |
| draft\_token   | 投机解码草稿 token              | `draft_token`   |

## 2. 判定规则

- 无法二分 prefill/decode：vLLM-Ascend 无 `record_function("prefill"/"decode")` 打点（`annotate_profile` 的 `execute_*` 注解仅 vLLM GPU 有，Ascend 未覆写）→ 改按顶层 repetitive scope 切五 stage。

- scope 名来自 `STRING_IDS.value`（`PYTORCH_API.name` JOIN 反查），来源筛 `type IN (50001, 50004)`（op + mstx）；`50002`（queue 封装）排除。

- 五 stage 每步重复出现 → 统计 count/累计/均值/最大/最小/首个；首个/特定位置用 `--inspect-index N` 细看。

## 3. 统计口径

- `count`：该 stage 出现次数（≈ 稳态 decode step 数）。

- `wall_time` = 累计，`wall_mean`/`wall_max`/`wall_min` = 单次均值/最大/最小，`first` = 首个起止/wall。

- 首 step 图捕获/编译噪声：由 step 拆解按位置（前 2 步）+ 阈值剔除，stage 层不单独剔除。

## 4. boundary（decode 单次 step 边界）

### 边界策略对应

| 策略         | vLLM 具体锚点                                                                            | 置信度 |
| ---------- | ------------------------------------------------------------------------------------ | --- |
| A 框架已有打点   | `forward` scope（record\_function，Ascend `model_runner_v1.py:2399`）/ DB `STEP_TIME` 表 | 高   |
| B 上层注入打点   | `execute_model` 前后注入 `record_function("step_N")` 或 MSTX 低开销 marker                   | 高   |
| C 数据推测（兜底） | lm\_head 前一层 / 首层 RMSNorm · embedding kernel（每 step 必现一次）                            | 中   |

- 锚点优先级：CLI `--anchor` 显式覆盖 > 场景资源 `step_decompose.anchor`（vllm 默认 `forward`）。

### C 策略锚点细则（decode）

- 锚点候选：`lm_head`（最后一层输出投影，每 step 出现一次）、采样前一层、首层 `input_layernorm`/embedding。

- 校验：锚点间距方差小 + 层数 == `num_hidden_layers / pp_size`（单卡层数）。

### capture\_size（图分桶，decode 归一化因子）——暂缓

- vLLM/昇腾把 decode forward 捕获成图（按 batch 分桶回放），per-step 耗时随 batch 变化。

- 必须识别每个 step 的 capture\_size（batch）作为归一化因子；否则最好/最差 step 对比被 batch 差异污染。

- 单 batch 量级下通常无 capture\_size 分桶切换；归一化留待多 batch 样本再验证。

## 5. 图捕获对层拆解的关键影响（layer-decompose 硬约束）

- 层内 scope（`vllm::dsa_forward` / `vllm::moe_forward_shared` / `vllm::matmul_and_reduce` / `vllm::maybe_all_reduce_tensor_model_parallel`）数量与层数一致，且全部落在捕获步内。

- 回放步不重放层内 scope（图回放只保留外层 `forward` + 通信流上的 `vllm::all_gather`/`reduce_scatter`）。

- 结论：**单层结构只能从捕获步取**；稳态 per-step 的层内归因不可得（图回放黑盒），结论阶梯上限 V2，归因到「单次执行」为止。

## 6. parallel\_default（PP）

- PP 按卡切层：每卡层数 ≈ `num_hidden_layers / pp_size`（embedding/lm\_head 挂靠首/末卡）。

- 建立 local 层序 ↔ global 层序映射（offset = rank\_in\_pp\_group × layers\_per\_rank）。

- 按 `Device ID` 分卡；跨 stage send/recv 通信归因到层间。

- 缺并行策略输入 → 按单卡处理并显式告警（见设计方案 §1）。

## 7. 框架行为（vLLM-Ascend）

- **无 prefill/decode scope**：`annotate_context_manager` 未覆写，`execute_*` 注解与 prefill/decode 字样均不落 → 五 stage 划分成立。

- **实际可见 scope 序列**（每 step 一轮）：`prepare input` → `forward` → `post process` → `sample_token` → `draft_token`（`prepare input` 首步多一次为初始化）。

- **step 边界锚点（A 策略）**：`forward` scope（vLLM-Ascend `model_runner_v1.py:2399`）是可靠 step 边界，每次 decode forward 出现一次。

- **采样 kernel =** **`sample_token`** **scope**（`vllm_ascend/worker/model_runner_v1.py:2570`），每 decode step 一次。

- **P-D 共部署（mixed）**：无法二分 prefill/decode；稳态下五 stage 每 step 一轮重复，统计口径适配。

- **send/recv 通信位置**：单卡无跨卡 send/recv；MoE 的 all2all 通信在 `PYTORCH_API` 中表现为 `vllm::all_gather` 与 `vllm::reduce_scatter`，并由 `analysis.db.CommAnalyzerTime` 提供 wait/sync/transit/idle 细拆。

