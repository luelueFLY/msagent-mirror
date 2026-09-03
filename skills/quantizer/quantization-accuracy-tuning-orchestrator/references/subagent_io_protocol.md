# 主 Agent ↔ Subagent 交互协议（MSAGENT_IO v1）

编排层通过 deepagents `task` 工具委派 subagent。主 Agent 在 `task.description`、Subagent 在最终回复中，须使用统一的 `msagent-io` 机器可读块。

各 subagent 的 `input` / `output` 字段定义见对应 reference；本文只规定**围栏格式、信封字段、职责边界**。

## 适用 subagent

自动调优流程中，以下 subagent **均须**遵守本协议：

| subagent | 职责 | 字段定义 |
|----------|------|----------|
| `msmodelslim-model-analysis` | 适配前模型分析（统一分析；DiT 识别 + 索取 `inference_repo`，回传 `next_step: model-adapt`） | [prepare_model.md](./prepare_model.md) |
| `msmodelslim-model-adapt` | 模型适配与验证（统一入口：LLM/VLM 主流程 + DiT 多模态生成扩展节） | [prepare_model.md](./prepare_model.md) |
| `quant-tuning-quantize-dit` | DiT W8A8 动态量化执行 | [quantization_tuning.md](./quantization_tuning.md) |
| `quant-tuning-infer-dit` | DiT 量化后推理验证（可选） | [quantization_tuning.md](./quantization_tuning.md) |
| `quant-tuning-evaluation-generator` | 生成测评配置 | [quantization_tuning.md](./quantization_tuning.md) |
| `quant-tuning-practice-generator` | 生成 Practice 配置 | [quantization_tuning.md](./quantization_tuning.md) |
| `quant-tuning-quantizer` | 执行量化 | [quantization_tuning.md](./quantization_tuning.md) |
| `quant-tuning-evaluator` | 执行精度评测（统一入口：LLM/VLM 主流程 + DiT 扩展节） | [quantization_tuning.md](./quantization_tuning.md) |
| `quant-tuning-score-dit` | DiT 评分（AISBench-VBench） | 本文件 §DiT 调优回路字段 |

> **DiT Practice YAML 修改** 不走 subagent，由 orchestrator 直接调
> `quantization-expert-experience-tuning-rules/scripts/apply_rollback.py`（整层回退，单一数字输入）。
> 详见 [`structure-family-pitfalls.md` §7](../../../quantization-expert-experience-tuning-rules/structure-family-pitfalls.md) 与 orchestrator SKILL.md §DiT 调优回路。

## 职责边界

| 角色 | 写什么 | 读什么 |
|------|--------|--------|
| **主 Agent** | `task.description` 中的 msagent-io 块（含 `input`） | Subagent 回传 msagent-io 块中的 `output` / `error` |
| **Subagent** | 最终回复中的 msagent-io 块（含 `status` + `output` 或 `error`） | 主 Agent 委派 msagent-io 块中的 `input` |

主 Agent **不得**伪造 Subagent 的 `output`；汇总结论须来自 Subagent 回传的 msagent-io 块。

## 消息结构（委派与回传统一）

每条消息由两部分组成：

- **块外**（可选）：≤3 行纯文本摘要
- **块内**（必选）：有且仅有一个 ` ```msagent-io v1 ` 围栏块

完整形态参考如下：

````markdown
<可选摘要，≤3 行>

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "<subagent 名称>",
  ...
}
```
````

约束：

1. 禁止第二个 msagent-io 块或重复 JSON
2. 块外**禁止**：长参数列表、SKILL 全文、完整 YAML/日志正文、重复 `input` 已有字段的执行细节
3. JSON 须可解析；`protocol` 固定为 `msagent.subagent_io`
4. 委派块**不含** `status` / `output` / `error`；回传块**不含** `input`

### 委派信封（主 Agent → task.description）

块外摘要规则见上文。以下**仅展示块内** msagent-io 围栏内容：

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "<与 task 参数 subagent_type 一致>",
  "input": { }
}
```

`input` 字段见上表对应 reference 中的 subagent 字段表。

### 回传信封（Subagent → 最终回复）

块外摘要规则见上文。以下**仅展示块内** msagent-io 围栏内容：

成功时（`status: "ok"` 时填 `output`，**不填** `error`）：

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "<本 subagent 名称>",
  "status": "ok",
  "output": { }
}
```

失败时（`status: "failed"` 时填 `error`，**不填** `output`）：

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "<本 subagent 名称>",
  "status": "failed",
  "error": {
    "code": "UNKNOWN_ERROR",
    "message": "简短错误描述"
  }
}
```

`output` / `error` 内具体字段见对应 reference，不在此重复。

### `commands` 字段（回传 `output` 内，涉及 CLI/脚本时必填）

当 subagent 通过 `execute` 运行 shell 命令或脚本时，须在 `output.commands` 中列出**实际执行**（或等价、可复现）的命令，供审计日志追溯。

每项结构：

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | string | 步骤标识，如 `quantize`、`sensitive_layer_analysis` |
| `command` | string | 完整 shell 命令；未执行时可省略 |
| `skipped` | bool | 未执行时为 `true` |
| `reason` | string | 跳过原因（可选） |

各 subagent 要求的 `name` 见 `quantization_tuning.md` 对应小节。

## 反例

| 反例 | 问题 |
|------|------|
| 整段自然语言参数列表、无 msagent-io 块 | 无法解析 |
| 块内缺少必填字段 | 委派不合规，须修正后重委派 |
| 块外重复 `input` 路径/设备说明或写执行步骤 | 违反「块外 ≤3 行摘要」 |
| 回传只有 Markdown 表格或纯自然语言（如「全部任务完成。」） | 无 msagent-io 块，不得作为有效结论 |
| 在 `output` 中粘贴完整 YAML / 日志正文 | 应只回传路径等结构化字段 |
| 回传同时含 `output` 与 `error`，或 `status` 与内容不匹配 | 信封字段冲突 |

quant-tuning 四类完整示例见 `quantization_tuning.md` 各 subagent 小节；msmodelslim 两类见 `prepare_model.md`。

## DiT 调优回路字段

> 本节定义 DiT 调优回路新增的 4 个 subagent 的 `input`/`output` 字段。
> 与 LLM/VLM 路径字段**不重叠**——避免主 agent 误用 LLM 模板。

### 共同约定

| 项 | 值 |
|---|---|
| 入口 | `subagent_type ∈ {"quant-tuning-evaluate", "quant-tuning-score-dit"}`（evaluate 为统一入口，DiT 走其扩展节） |
| 输入路径 | 由 orchestrator 在 `user_input` 阶段从用户收集；`--device` 仅字面量 `npu` / `cuda` / `cpu` |
| 输出路径 | `{workdir}/round_{N}/quantized/`、`{workdir}/infer_outputs/round_{N}/`、`{workdir}/baseline_outputs/` 等约定目录 |
| 评分 | DiT 扩展节的 `score` 字段保持 `null`（不评分）；真实评分由 `quant-tuning-score-dit` 跑出 `scores` / `overall_score` / `loss_vs_baseline` / `is_satisfied` |

### Agent: quant-tuning-quantize-dit（既有 + DiT 调优复用）

> 字段表见既有 `quantization_tuning.md` §Agent: quant-tuning-quantizer；DiT 调优复用时仅 `config_path` 取自 `apply_rollback.py` 的 `--output-practice`。

### Agent: quant-tuning-evaluate（DiT 扩展节）

> 执行细节（bash 模板、ALGO 决策、FSDP 约束、心跳机制）见 [`quant-tuning-evaluate/references/dit/evaluate_workflow.md`](../../../quant-tuning-evaluate/references/dit/evaluate_workflow.md)；量化 flag 名**不查任何 preset 表**，agent 直接读 `<inference_repo>/README.md` 确认（Wan2.2 → `--quant_dit_path`）。

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `INFER_REPO` | string | ✅ | 推理仓绝对路径（须自带 `vbench.py`） |
| `FP_WEIGHTS` | string | ✅ | FP base model 目录（→ `--ckpt_dir`，**始终必填，量化/FP baseline 都用**） |
| `QUANT_WEIGHTS` | string | ⛏️ | 量化产物目录（→ 量化 flag 如 `--quant_dit_path`；FP baseline 时不填） |
| `OUT_DIR` | string | ✅ | 量化推理 → `{workdir}/infer_outputs/round_{N}/`；**FP baseline → `{workdir}/baseline_outputs/`** |
| `ROUND` | int | ✅ | orchestrator 轮次 |
| `NPROC` | int | ✅ | torchrun 卡数（= `cfg_size × ulysses_size`，≤ 可见 GPU 数） |
| `VBENCH_ARGS` | string[] | ✅ | vbench.py argv（agent 按推理仓 README 自拼，含 `--ckpt_dir $FP_WEIGHTS`） |
| `device` | string | | 默认 `npu`；卡号通过 `ASCEND_RT_VISIBLE_DEVICES` |

回传 `output` 必填：`ok`, `exit_code`（校验失败 = `2`，stderr 附 `VBENCH_ARGS_INVALID`）, `log_path`（`vbench_runner.log`）, `manifest_path`（`run_manifest.json`）；不评分（评分由 `quant-tuning-score-dit` 接力）。**无硬超时**：模板以 60s heartbeat 汇报存活，orchestrator 不得按固定 timeout 误杀。

**FP baseline 模式**：`QUANT_WEIGHTS` 留空，输出写到 `{workdir}/baseline_outputs/`。orchestrator 启用前必须回显预估时长（FP 比量化慢 1.5-3×）。
**关键约定**：`--ckpt_dir` 始终指向 FP base model；vbench.py 内部 T5/VAE 等子模块也按 FP 加载；量化推理**同时**要传 FP + 量化两个路径（量化 flag 名按推理仓）。

### Agent: quant-tuning-score-dit

> 执行细节（缓存检查、用户确认、NPU 卡号拼接）见 [`quant-tuning-score-dit/SKILL.md`](../../quant-tuning-score-dit/SKILL.md)；本节只列字段。

| 字段 | 类型 | 必填 | CLI flag | 说明 |
|---|---|---|---|---|
| `infer_outputs` | string | ✅ | `--infer-outputs` | `{workdir}/infer_outputs/round_{N}/`（evaluate DiT 扩展节产出） |
| `full_json_dir` | string | ✅ | `--full-json-dir` | VBench `kmeans_info*.json` 目录 |
| `vbench_cache_dir` | string | ✅ | `--vbench-cache-dir` | 预填充的 VBench cache |
| `baseline_outputs` | string | ⛏️ | `--baseline-outputs` | `{workdir}/baseline_outputs/`（启用 FP 对比时） |
| `score_dimensions` | string[] | ⛏️ | `--score-dimensions` | 维度子集，缺省全维度 |
| `baseline_tolerance` | float | ⛏️ | `--baseline-tolerance` | 默认 `0.05`；`is_satisfied ⇔ loss_vs_baseline ≥ -tolerance` |
| `round` | int | ⛏️ | `--round` | orchestrator 轮次 |

回传 `output` 必填：`ok`, `scores`（每维度）, `score_dimensions`, `quality_score`, `semantic_score`, `overall_score`, `commands`, `duration_sec`；启用 `--baseline-outputs` 时追加 `loss_vs_baseline`, `is_satisfied`（orchestrator 调优回路的退出信号）

> 评分字段经 `quant-tuning-history-append-dit` 透传到 `history.yaml.dit_records[]`；当前仅实现 `vbench` 评分器（无 `scorer` 参数，后续扩展 `image_reward` / `clip_score` 时再加）。

## 回传检查（主 Agent）

`task` 返回 Subagent 原文，不附带校验标志。须从回传中解析 msagent-io 块：

- `status: "ok"` → 读 `output`
- `status: "failed"` → 读 `error`
- 无块或无法解析 → 重试或判该步失败，**不得**用自然语言摘要代替
