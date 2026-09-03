# 输出格式规范

## 适用与不适用

- **适用**：所有 `model_family ∈ {llm, vlm_text, dit}` 的调优记录
- **不适用**：模型分析 / 适配器生成（属 `prepare_model.md`）

## 1. 主对话层输出

主 Agent 在向用户回显结果时，**必须**包含以下章节：

```
## 调优结果摘要
- 模型类型: <model_type>
- 工作目录: <workdir>
- 历史最佳轮次: round_<N>（精度 <score>，与 FP 差异 <loss>）
- 量化产物: <workdir>/round_<N>/quantized/
- 评测产物: <workdir>/infer_outputs/round_<N>/ (或 service_oriented 报告路径)

## 关键命令
<按时间顺序记录 3-5 条最关键命令，敏感层分析/量化/评测；不输出长日志>

## 后续步骤
- [若未达标] 下一轮调优策略建议
- [若达标] 推荐权重路径 + 使用方式
```

> **DiT 调优回路**：`quant-tuning-score-dit` 已实现 AISBench-VBench 评分；评分字段（`overall_score` / `loss_vs_baseline` / `is_satisfied`）在用户启用 `--baseline-outputs` 时由 subagent 注入并写入 `history.yaml`，主对话摘要据实回显；若未启用评分聚合则保持 `null`。

## 2. workdir 目录结构

```
{workdir}/
├── round_1/
│   ├── practice.yaml                  ← 量化方案
│   └── quantized/                     ← 量化权重
├── round_2/
│   ├── practice.yaml                  ← 调优第 1 轮 YAML（含 rollback_rules 追加的 exclude）
│   └── quantized/
├── round_N/
│   ├── practice.yaml
│   └── quantized/
├── infer_outputs/                     ← （DiT 路径；每轮产物落盘）
│   └── round_N/<subdir>/<idx:04d>.<ext>
├── baseline_outputs/                  ← （DiT 路径；仅当启用 baseline 时）
│   └── <subdir>/<idx:04d>.<ext>
├── history/
│   └── history.yaml                   ← 每轮记录（见 §3）
├── logs/
│   └── *.log                          ← 命令日志
└── ...
```

> **磁盘管理**：
> - 视频产物（`infer_outputs/`、`baseline_outputs/`）**不删**（DiT 决策 C）
> - 权重（`round_*/quantized/`）按 LLM 规则管，最多 2 份（当前轮 + 历史最优轮）
> - 历史 YAML 与日志全保留

## 3. `history.yaml` 结构

每轮调优结束后由 `history_append` / `history_append-dit` 追加一条记录。LLM/VLM 与 DiT 字段**重叠但不冲突**——LLM 路径填 `scores`，DiT 路径填 `inference_outputs` + `score=null`。

```yaml
records:
  - practice_id: dit-round-2                  # 唯一 ID
    quant_config_md5: 44c42e68...             # practice.yaml 的 md5
    time: '2026-08-08 12:34:56.789'

    # --- LLM/VLM 路径字段（DiT 路径写 null）---
    evaluation:
      accuracies: null
      expectations: null
      is_satisfied: null

    # --- DiT 路径字段（LLM/VLM 路径不写）---
    inference_outputs:
      - "{workdir}/infer_outputs/round_2/overall_consistency/0000.mp4"
      - "{workdir}/infer_outputs/round_2/subject_consistency/0001.mp4"
    fp_baseline_outputs: null                 # 仅 quant-tuning-evaluate DiT 扩展节 FP baseline 模式启用时填（--ckpt_dir → FP 权重）
    scores: null                              # 由 quant-tuning-score-dit 写入；用户未触发时为 null
    overall_score: null                       # 由 quant-tuning-score-dit 写入；用户未触发时为 null
    loss_vs_baseline: null                    # 启用 --baseline-outputs 后写入
    is_satisfied: null                        # 启用 --baseline-outputs 后写入；orchestrator 据此判定退出回路
```

## 4. 回传 envelope（subagent → 主 Agent）

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "<subagent 名>",
  "status": "ok" | "failed",
  "output": { /* 见各 subagent §output 字段 */ },
  "error": { "code": "<短码>", "message": "<短描述>" }   # 仅 failed 时
}
```

详见 [`subagent_io_protocol.md`](./subagent_io_protocol.md)。

## 5. 块外摘要约束

主 Agent 调用 subagent 时，`description` 块外（msagent-io 围栏外）必须**≤3 行纯文本摘要**：

```markdown
调用 quant-tuning-evaluate（DiT 扩展节）跑 round_2 推理（testset=vbench_mock_2.jsonl）

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "quant-tuning-evaluate",
  "input": { ... }
}
```

> DiT 调优回路的 YAML 改写**不**走 subagent 协议 — orchestrator 直接调
> `quantization-expert-experience-tuning-rules/scripts/apply_rollback.py`，CLI stdout JSON 即为结果。

禁止：
- 长参数列表
- SKILL 全文
- 完整 YAML / 日志正文
- 重复 `input` 已有字段的执行细节

## 6. 反模式

| 反模式 | 原因 |
|---|---|
| 主对话输出 ≥50 行长日志 | 违反"简短回答"原则 |
| 改写或伪造 subagent 回传 | 违反"主 Agent 不得伪造 Subagent 的 output" |
| 跨 model_family 共享字段 | DiT 字段（`inference_outputs`）绝不写到 LLM 记录的 `evaluation.accuracies` |
| 引入 DiT 专属输出路径名 | 与 LLM/VLM 路径共存，不分裂 |
