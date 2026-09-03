# 核心工作流（创建 + 独立验证触发）

本 Skill 负责基础适配器创建，并在完成后触发独立验证 Skill。

## 阶段 0：权重来源确认（先确认再下载）

1. 先要求用户提供模型权重（本地目录或可访问路径）。
2. 若用户已提供权重，直接使用用户权重继续后续流程。
3. 仅当用户明确确认"没有可用权重"时，再协助下载模型。
4. 结构分析可先下载非权重文件；进入完整量化与验证前，需确保权重已补齐。

## 阶段 A：创建适配器

1. 选择模板：
   - LLM 使用 `model_adapter_template.py`
   - VLM 文本路径使用 `vlm_model_adapter_template.py`
2. 实现必需接口。
3. 在 `config/config.ini` 中注册模型类型与入口。

### 阶段 A.DiT（仅当模型族识别为多模态生成时执行）

> 触发条件：模型族识别为 DiT/扩散（信号如 `_diffusers_version`、msmodelslim `config/config.ini` 多模态生成族、关键词 `文生视频 / 扩散 / Wan / FLUX / SD3`）。
> 识别入口：复用 `msmodelslim-model-analysis` 的结论；失败时进入本路径。
> 多模态生成模型**必须由用户单独提供 `inference_repo`**（与权重目录互不包含）；用 `AskUserQuestion` 强提示并强制要求，仅做"路径存在且为目录"校验。

进入本路径后，**全部 DiT 实现细节**（目录结构、模板、11 接口、行为差异、注册、checklist）见：
[dit/implementation_guide.md](dit/implementation_guide.md)。

**主路径不再重复 DiT 内容。** agent 读完该文件即可完成 DiT 适配器创建。

## 阶段 B：触发功能性验证（独立 Skill）

1. 适配器开发完成后，明确告知用户可自动执行功能性验证。
2. 调用独立 Skill：`msmodelslim-adapter-verification`。
3. 由该 Skill 按四步自动完成验证并返回结果。

### 阶段 B.DiT（验证 flag 差异）

调用 `msmodelslim-adapter-verification` 时，DiT 任务必加：

| flag | 含义 |
|------|------|
| `--skip-random-model` | DiT 不接受随机权重生成 |
| `--model-family dit` | 标识 DiT 族 |
| `--inference-repo <path>` | 推理仓路径 |
| `--reference-weights <path>` | 参考权重路径 |
| `--rules-path <path>` | 描述文件规则路径 |

每步 `passed=true` 才视为通过；任一失败即中止并回传 `status: failed`。

## 验收规则

仅当阶段 A 完成，且阶段 B 的独立验证 Skill 返回通过时，才将适配器标记为完成。
