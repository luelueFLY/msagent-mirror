# 模型准备

## 阶段说明

**模型准备阶段**是端到端自动量化与调优流程编排的第 3 阶段。在本阶段，你需要确保目标模型已被 msModelSlim 支持并完成适配，使后续量化配置调优阶段可以正常调用。

## 执行依赖项

### 子代理

由三个专用子代理承载模型分析与适配工作；主代理 **不要**在本会话中代替 subagent 完成分析或适配。

| 子代理 | 功能用途 |
|--------|----------|
| `msmodelslim-model-analysis` | 适配前分析：实现来源解析、结构/MoE/逐层加载等风险评估；DiT/扩散场景下识别 `model_family=dit` 并索取 `inference_repo` |
| `msmodelslim-model-adapt` | 模型适配与验证（统一入口）：LLM/VLM 走主流程；`model_family=dit` 走多模态生成扩展节（适配器生成 + 四步验证） |
| `msmodelslim-anti-outlier-adapt` | 基础适配验证通过后：用已安装 msModelSlim API 提取逐算法 DOT 图并执行独立 logits 门禁 |

> DiT 适配细节与四步验证由 `msmodelslim-model-adapt` 的 DiT 扩展节承载（工作流见 `msmodelslim-model-adapt/references/dit/adaptation_workflow.md`），orchestrator 仅负责按 `model_family` 路由与产物串联——分析回传 `next_step: model-adapt` 后委派 `msmodelslim-model-adapt`，与 LLM/VLM 委派方式一致。

## 执行流程

### 1. 检查模型是否已支持

查询用户提供的 `model_type` 是否已在 `msmodelslim/config/config.ini` 的 `[ModelAdapter]` 中注册。注意 `model_type` 不是模型权重路径中 `config.json` 里的 `model_type`，一般形如 `Qwen3-32B`、`DeepSeek-V3`。如果已注册且基础适配四步验证有效，则跳过基础适配；选定算法的逐算法 DOT、logits 门禁或汇总报告不完整时仍须执行独立的离群值抑制流程。

### 2. 委派模型分析

若模型未注册，委派 `msmodelslim-model-analysis` subagent。调用 `task` 时 `description` **必须**包含 MSAGENT_IO 块，字段见下文。

**DiT/扩散场景特殊流程**：分析层识别为 `model_family ∈ dit` 后，会通过 `output.detection_source` 标记需要用户提供 `inference_repo`。主 Agent 收到该信号后**必须**用 `AskUserQuestion` 向用户索取推理仓绝对路径，再以 `input.inference_repo` 字段重新委派分析层（或直接以新字段继续），分析层据此写入报告。

### 3. 委派模型适配

- **LLM/VLM 路径**：仅当分析回传 `next_step: "model-adapt"` 时，委派 `msmodelslim-model-adapt` subagent。`next_step: "dequant"` 时先走反量化 skill；`blocked` / `need_user_input` 时停止并向用户说明（细节见 `summary` 与 `report_path`）。`description` **必须**包含 MSAGENT_IO 块，字段见下文。
- **DiT 路径**：与 LLM/VLM 同一委派流程。分析识别为 DiT 且缺 `inference_repo` 时回传 `next_step: need_user_input`，主 Agent 用 `AskUserQuestion` 取得推理仓路径后，**再次委派同一 subagent** `msmodelslim-model-analysis` 并带上 `inference_repo`；分析回传 `next_step: model-adapt`（附 `model_family: dit`、`inference_repo`）后，委派 `msmodelslim-model-adapt` 并在 `input` 附 `inference_repo`，由其 DiT 扩展节完成适配器生成与四步验证。

### 4. 委派离群值抑制适配

只有步骤 3 的基础适配及四步验证全部通过后才进入此步骤，单独调用
`msmodelslim-anti-outlier-adapt` 完成，主 Agent 不代为执行。用户未指定算法时执行默认四项
`quarot`、`flex_smooth_quant`、`flex_awq_ssz`、`iter_smooth`；用户明确指定时执行其所选
子集。每项从同一原始 checkpoint 单独加载干净模型、只应用一个 processor、记录最终 logits，
不得串联算法、复用已变换模型或执行量化，并产生独立 DOT、JSON 比较结果和汇总
`anti_outlier_report.md`，不向后续调优流程输出能力矩阵。执行配置读取 msModelSlim 官方
`*_default` 模板；不得在 msAgent 仓库新增结构扫描、hook 或 formatter 脚本，不得依赖源码树
`docs/zh`。

### 5. 最终验证

确认以下条件均已满足后，方可进入下一阶段（量化配置调优）：

- [ ] 模型适配已完成，适配器已注册
- [ ] 模型权重文件完整可加载
- [ ] 模型可在目标设备（NPU）上正常执行前向推理
- [ ] 已通过 msModelSlim `fast_ops_grapher` 为每个选定算法生成非空 DOT 图
- [ ] 每个选定算法均已独立完成 processor 与变换前后浮点 logits 门禁
- [ ] 已生成包含逐算法对比结果和逐算法图链接的 `anti_outlier_report.md`

若上述任何步骤失败，须向用户明确报告原因并停止流程。

## 注意事项

- 禁止在本会话中代替 subagent 完成分析或适配代码编写
- 分析阶段判定阻塞时，不得强行进入适配或调优
- 适配完成后，按 `config.ini` 注册格式确认 `model_type` 已正确添加

## 拉起 subagent 的格式（MSAGENT_IO v1）

协议总则见 [subagent_io_protocol.md](./subagent_io_protocol.md)。本文档面向**主 Agent**：定义委派 `input` 与回传 `output` 业务字段；`commands` 见协议。完整 output 示例见各 subagent prompt。

调用 `task` 时，`description` **必须**包含一个 ` ```msagent-io v1 ` JSON 块。

### Agent: msmodelslim-model-analysis

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `model_type` | string | ✓ | msModelSlim 注册名，如 `Qwen3-8B` |
| `model_path` | string | ✓ | 模型权重目录 |
| `trust_remote_code` | bool | | 默认 `true` |
| `save_path` | string | | 工作目录；分析报告写入 `{save_path}/model_analysis_report.md` |
| `inference_repo` | string | | DiT/扩散专用：用户提供的推理仓绝对路径。首次委派可缺省；分析层识别为扩散模型后回传 `detection_source` 暗示需要该字段，主 Agent 用 `AskUserQuestion` 取得后再次委派时必填 |

回传 `output` 必填：`next_step`（`model-adapt` / `dequant` / `blocked` / `need_user_input`），`implementation_source`（`transformers` / `model-local` / `diffusers` / `blocked`），`summary`，`report_path`，`commands`（有 shell 执行时）；
DiT 路径（`model_family ∈ dit` 且 `next_step: model-adapt`）额外必填：`model_family`（`dit`），`inference_repo`（用户提供的绝对路径）

委派模板（LLM/VLM 用）：

````markdown
```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "msmodelslim-model-analysis",
  "input": {
    "model_type": "Qwen3-8B",
    "model_path": "/data/models/Qwen3-8B/",
    "trust_remote_code": true,
    "save_path": "/path/to/workdir/"
  }
}
```
````

委派模板（DiT 二次委派，带 `inference_repo`）：

````markdown
```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "msmodelslim-model-analysis",
  "input": {
    "model_type": "Wan2.2-T2V-A14B",
    "model_path": "/data/models/Wan2.2-T2V-A14B/",
    "trust_remote_code": true,
    "save_path": "/path/to/workdir/",
    "inference_repo": "/path/to/wan2_2_inference_repo/"
  }
}
```
````

### Agent: msmodelslim-model-adapt

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `model_type` | string | ✓ | msModelSlim 注册名 |
| `model_path` | string | ✓ | 模型权重目录 |
| `trust_remote_code` | bool | | 默认 `true` |
| `analysis_report_path` | string | ✓ | 步骤 2 产出的分析报告路径 |
| `save_path` | string | | 适配工作目录 |
| `inference_repo` | string | | DiT/扩散专用：推理仓绝对路径（取自分析回传的 `output.inference_repo`）；LLM/VLM 不需要 |

回传 `output` 必填：`adapter_registered`，`verification_steps`（四步全 `passed: true` 即通过），`artifact_paths`（可选），`commands`（须含 `install` 与 `verification_step1`～`verification_step4`）；
DiT 路径（`model_family ∈ dit`）额外必填：`model_family`（`dit`），`inference_repo`，`artifact_paths`（含 `adapter_py` / `config_ini`）

委派模板（LLM/VLM 用）：

````markdown
```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "msmodelslim-model-adapt",
  "input": {
    "model_type": "Qwen3-8B",
    "model_path": "/data/models/Qwen3-8B/",
    "trust_remote_code": true,
    "analysis_report_path": "/path/to/workdir/model_analysis_report.md",
    "save_path": "/path/to/workdir/"
  }
}
```
````

委派模板（DiT 用，附 `inference_repo`）：

````markdown
```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "msmodelslim-model-adapt",
  "input": {
    "model_type": "Wan2.2-T2V-A14B",
    "model_path": "/data/models/Wan2.2-T2V-A14B/",
    "trust_remote_code": true,
    "analysis_report_path": "/path/to/workdir/model_analysis_report.md",
    "save_path": "/path/to/workdir/",
    "inference_repo": "/path/to/wan2_2_inference_repo/"
  }
}
```
````

### 关于原 quant-tuning-analyze-dit

DiT 分析已并入 `msmodelslim-model-analysis`（统一分析），DiT 适配器生成与四步验证由 `msmodelslim-model-adapt` 的 DiT 扩展节承接——两个阶段均通过上文两个 Agent 节的字段契约委派，无需独立 subagent。

