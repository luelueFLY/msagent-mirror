---
name: msmodelslim-model-analysis
description: 在实现适配器前对候选模型做分析。确定模型实现来源（transformers / 模型目录 / diffusers）、结构特征、内存约束下的逐层量化建议（可选）及 MoE 融合权重风险。适用于用户询问模型适配可行性或做适配前分析时使用。识别为 DiT 扩散模型时，索取推理仓路径后回传 `next_step: model-adapt`，由 orchestrator 委派 `msmodelslim-model-adapt`（DiT 扩展节承接）。
---

# 模型分析 Skill

## 适用范围

- 支持：
  - Decoder-only LLM
  - VLM 文本主干分析（仅 LLM/文本路径）
  - DiT 扩散模型（如 FLUX.1-dev、SD3、Wan、Sana、HunyuanDiT、CogViewX、SD1.5/SDXL 等 DiT 扩散）
- 不支持：
  - 既非 transformers 也非模型目录内 `modeling_*.py` 的实现
  - DiT 场景下未提供推理仓路径的实现

## 必需输入

- 模型路径或模型仓库标识
- `config.json`
- 可选：模型目录内 `modeling_*.py`、`model.safetensors.index.json`
- 若本地缺少上述文件，先补齐输入：
  - 使用 `modelscope download --model <org>/<model> --local_dir ./models/<name> --exclude '*.safetensors'` 下载非权重文件。
  - 在下载目录中读取 `config.json` 与 `modeling_*.py`，作为后续分析输入。

## 硬门禁：先解析实现来源

在进行任何结构分析前必须完成。Agent 应按以下步骤手动解析，无需脚本：

1. **读取 `config.json`**：
   - 获取 `model_type`
   - 获取 `auto_map`（如有）

2. **尝试从 transformers 解析实现**：
   - 检查 `transformers` 库是否支持该 `model_type`。
   - 检查路径：`transformers/models/<model_type>/modeling_<model_type>.py` 是否存在。
   - 如果存在，记录为 `transformers` 实现。

3. **若未解析到，尝试模型目录内实现**：
   - 检查 `auto_map` 指向的文件是否存在于模型目录。
   - 检查模型目录内是否有 `modeling_*.py` 文件。
   - 如果存在，记录为 `model-local` 实现。

4. **尝试 diffusers 实现路径**（仅当 2、3 均未命中时）：
   - 检查模型目录或其一级子目录下的 `*.json` 是否包含 `_diffusers_version` 字段（如 `model_index.json`）。
   - 若命中，记录为 `diffusers` 实现；`model_family` 判定为 `dit`。
   - 此时**必须**额外询问用户提供**推理仓路径**（参见下文 §识别扩散模型后：获取推理仓路径），不得由 Agent 自动猜测。

5. **若以上三种路径均不可用**：
   - 停止分析。
   - 要求用户提供可读的模型实现代码。

## 最小工作流

1. 解析实现来源（完成上述硬门禁）。
2. 判断模型类型、结构差异与连接关系：
   - 类型：纯 LLM / 多模态理解模型 / 多模态生成模型
   - 对比常见 Qwen2 类 LLM，记录特殊结构设计（如 MoE、非标准 attention、SSM/混合块、额外头部或并行分支）
   - 检查特殊结构连接关系（接入位置、前后依赖、串联/并联/残差连接、是否影响主干遍历）
3. 识别结构特征：
   - decoder 层类、attention/MLP 模块命名、forward 签名
4. 确定影响适配的特征：
   - 层遍历路径与顺序
   - 是否存在内存约束导致需要逐层量化（可选高阶特性）
   - MoE 融合专家权重风险
   - 量化模型反量化脚本风险
   - MTP 结构实现可得性与权重处理风险
5. 产出结构化分析结果（参考下方模板）。
6. 给出后续动作（统一契约，不区分模型族）：
   - 若判定为原生量化模型，优先进入 `msmodelslim-model-dequant`
   - `llm` / `vlm_text` / `dit`：回传 `next_step: model-adapt`（DiT 需附 `model_family` 与 `inference_repo`），由 orchestrator 委派 `msmodelslim-model-adapt`（DiT 走其多模态生成扩展节）
   - 或阻塞并说明需用户提供的内容

### 模型类型、结构差异与连接关系判定（相对常见 Qwen2）

- `纯 LLM`：仅文本 token 输入，主干为 decoder-only 语言模型。
- `多模态理解模型`：含视觉/音频等编码器，但生成路径以文本主干为核心，允许仅分析并适配文本部分。
- `多模态生成模型 / DiT / 扩散`：核心目标是图像/视频/语音生成；分析层只做识别与索取推理仓路径，适配由 orchestrator 委派 `msmodelslim-model-adapt`（DiT 扩展节）承接；详见下文 `识别扩散模型后：获取推理仓路径`。
- 结构差异只需记录“是否存在 + 影响方向”，不要求深入实现细节。
- 连接关系至少记录：特殊结构位于主干的哪个阶段、与哪些模块相连、连接方式（串联/并联/残差）及对遍历/forward 对齐的影响。

### 识别扩散模型后：获取推理仓路径（强制交互）

当判定 `model_family ∈ dit` 时，**必须**通过对话向用户索取**独立的扩散模型推理仓路径**，因为 DiT 的实现代码（`modeling_*.py` / `pipeline/` / `quant/`）通常不在权重目录内。

- 提示语模板：
  > 检测到该模型为 DiT/扩散生成模型。此类模型的实现代码位于独立的**推理仓**中，与权重目录分离。请提供推理仓的本地路径（例如：`/home/limingyu/Develop/FLUX.1-dev-CODE/FLUX.1-dev/FLUX1dev/`）。
- 仅做"路径存在且为目录"的最基础校验；严禁基于"典型子包是否存在"等启发式判定路径合法性，以免误拒合法推理仓。
- 校验通过后写入 `analysis_result.yaml.inference_repo`。
- 推理仓与权重仓**互不包含**，结构差异大，禁止统一结构校验。

### DiT 输出字段

判定 `model_family ∈ dit` 后，输出以下字段：

```yaml
model_family: dit            # ∈ {llm, vlm_text, dit}
implementation: diffusers    # ∈ {transformers, model_local, diffusers}
detection_source: file_marker # ∈ {llm_vlm_path, file_marker, dialogue, user_input}
inference_repo: /abs/path/to/inference_repo  # 仅 DiT/扩散需要
```

### MoE 布局判定

- `MoE 非融合`：专家按模块/列表展开（常见为每个 expert 各自持有 `gate/up/down` 线性层）。
- `MoE 融合`：多个 expert 的权重被打包为张量参数，不再是一组独立线性层。
- 若看到 `gate/up/down` 中任一或多项以 `[..., num_experts, ...]` 或 `[num_experts, ...]` 形式存储，应按“融合”处理。
- 对三维专家权重（如 gate/up/down 分别融合成 3D 参数）统一归类为 `MoE 融合`，并在报告中标注“可能需要 unpack”。

## 必需输出：分析报告

Agent 应直接生成分析报告（Markdown 格式），内容必须包含以下要素。请参考下方模板：

```markdown
# 分析报告

## 模型标识
- 模型路径/仓库：{model_path}
- `model_type`：{model_type}
- `architectures`：{architectures}
- `model_family` ∈ {llm, vlm_text, dit}
- `implementation` ∈ {transformers, model_local, diffusers}
- `inference_repo`：{仅 DiT/扩散需要}
- `detection_source` ∈ {llm_vlm_path, file_marker, dialogue, user_input}

## 实现来源解析
- 结果：`transformers` | `model-local` | `diffusers` | `unsupported`
- 依据：
  - 解析到的文件路径：{path}
  - 相关配置字段（`model_type`、`auto_map`、`_diffusers_version`）：{details}

## 模型特征与规格
- Hidden size：{hidden_size}
- 层数：{num_layers}
- Attention heads / KV heads：{num_heads} / {num_kv_heads}
- 是否仅分析 VLM 文本部分：是/否

## 模型类型、结构差异与连接关系
- 模型类型：纯 LLM | 多模态理解模型 | 多模态生成模型 / DiT | DiT 扩散
- 相对常见 Qwen2 的特殊结构：{special_structures}
- 特殊结构连接关系：{special_structure_connections}
- 对适配流程的影响：{structure_impact}

### DiT 专属（仅当 model_family ∈ dit 时填写）
- 条件注入路径：{text/img/mask → 主干的注入点}
- 时间步嵌入位置：{timestep embedding 所在模块}
- Attention 类型清单：{self / cross / linear}
- 双专家结构：{是 / 否；若是为 low_noise_model / high_noise_model 各自 `init_model` key}
- 量化服务：MultimodalSDModelslimV1QuantService
- YAML `apiversion`：multimodal_sd_modelslim_v1

## 逐层量化建议（可选高阶特性）
- 是否建议逐层量化：是/否
- 触发原因（如 CPU 内存无法全量加载权重）：{reason}
- 约束（内存/运行环境）：{constraints}
- 说明：逐层量化不是基础适配必需项，建议在基础适配与四步验证完成后再进入 `msmodelslim-layer-wise-quantization`

## MoE 评估
- 是否含 MoE：是/否
- 布局类型：无 MoE | MoE 非融合 | MoE 融合
- 疑似融合的键/模块：{keys}
- 专家权重形态：独立线性层 | 打包张量（含 3D 专家权重）
- 是否需要 unpack：是/否

## 适配影响要点
- Decoder 遍历路径：{traversal_path}
- Attention 模块命名：{attn_module}
- MLP 模块命名：{mlp_module}
- `visit/forward` 严格对齐点：{alignment_points}

## 量化与 MTP 风险评估
- 模型是否已量化：是/否
- 量化判定依据：{quant_evidence}
- 是否已提供反量化脚本：是/否
- 反量化脚本状态说明：{dequant_status}
- 是否存在 MTP 结构：是/否
- MTP 实现代码可获取性：可获取/不可获取
- MTP 风险说明：{mtp_risk}

## 风险与后续动作
- 风险等级：低 | 中 | 高
- 阻塞项：{blockers}
- 建议下一步：
  - DiT：进入 DiT 适配（orchestrator 委派 `msmodelslim-model-adapt`，走其多模态生成扩展节，工作流见 `msmodelslim-model-adapt/references/dit/adaptation_workflow.md`）
  - LLM/VLM：进入 `model-adapt-core`（orchestrator 委派 `msmodelslim-model-adapt`）
  - 或要求用户提供实现代码
```

### 风险识别与用户沟通要求（必须执行）

- 若识别为“原生量化模型”（模型权重本身已量化），必须先调用 `msmodelslim-model-dequant` skill 再继续后续适配流程。
- 若识别为“模型本身已量化”，必须将“缺少反量化脚本”标记为阻塞项，并明确要求用户主动提供反量化脚本后再继续适配。
- 若识别到存在 MTP 结构但无法获取其实现代码，必须明确告知：
  - Agent 可能无法完整实现 MTP 结构适配；
  - 如需继续，用户需要自行复制 MTP 相关权重（按用户侧已有实现进行映射）。
- 上述两类风险至少有一项命中时，`风险等级` 不得低于“中”。

## 通过/失败标准

- 通过：
  - 实现来源为 `transformers` / `model-local` / `diffusers` 三者之一；
  - 模型类型为纯 LLM / 多模态理解模型 / DiT 扩散中对应合法类型；
  - 报告完整；若为 DiT/扩散，已获得推理仓路径且 `inference_repo` 已写入；
  - 若命中量化/MTP 风险，已在报告中给出明确用户动作要求。
- 失败：来源未解析、为不支持的实现类型，或命中“量化模型但无反量化脚本”阻塞条件；DiT/扩散场景下未提供推理仓路径。

## 输出（向 orchestrator 回传）

协议为 `msagent.subagent_io`；以下为业务字段。

**通用必填**（LLM/VLM 与 DiT 均要求）：
- `next_step` ∈ {`model-adapt`, `dequant`, `blocked`, `need_user_input`}
  - `model-adapt`：分析通过，等 orchestrator 委派 `msmodelslim-model-adapt`（DiT 由其多模态生成扩展节承接）
  - `dequant`：命中原生量化模型，需先委派 `msmodelslim-model-dequant`
  - `blocked`：存在阻塞项
  - `need_user_input`：DiT 首次识别需索取推理仓路径（orchestrator 用 `AskUserQuestion` 取得后带 `inference_repo` 二次委派）
- `implementation_source` ∈ {`transformers`, `model-local`, `diffusers`, `blocked`}（报告中的 `implementation` 字段回传到此）
- `summary`、`report_path`（即 `model_analysis_report.md`）、`commands`（有 shell 执行时）

**DiT 路径额外必填**（`next_step ∈ {model-adapt, need_user_input}` 且 `model_family ∈ dit` 时）：
- `model_family`（`dit`）；`next_step=model-adapt` 时还需 `inference_repo`（用户提供的推理仓绝对路径）

DiT 成功信封示例：

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "msmodelslim-model-analysis",
  "status": "ok",
  "output": {
    "next_step": "model-adapt",
    "model_family": "dit",
    "implementation_source": "diffusers",
    "summary": "...",
    "report_path": "<save_path>/model_analysis_report.md",
    "inference_repo": "<用户提供的推理仓绝对路径>"
  }
}
```

失败信封（所有路径统一）：

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "msmodelslim-model-analysis",
  "status": "failed",
  "error": {
    "code": "<error.code>",
    "message": "<一句话现象与根因>",
    "suggestion": "<给 orchestrator 的下一步动作建议>"
  }
}
```

`error.code` 约定：`CONFIG_ERROR`（输入/路径不合法）、`ANALYSIS_FAILED`（实现来源未解析/结构分析失败）、`ADAPTER_ERROR`（DiT 适配器生成失败）、`VERIFICATION_FAILED`（四步验证任一步失败）、`ADAPTER_ERROR`（DiT 适配器生成失败）、`VERIFICATION_FAILED`（四步验证任一步失败）、`BLOCKED`（量化模型无反量化脚本等阻塞项）。配置类错误（`CONFIG_ERROR`）立即中止不重试。

## 参考

- [分析检查清单](references/analysis_checklist.md)
- [DiT 适配工作流（由 msmodelslim-model-adapt 执行）](../msmodelslim-model-adapt/references/dit/adaptation_workflow.md)
