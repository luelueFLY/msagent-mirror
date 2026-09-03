# DiT 适配工作流

> **本文档定位**：DiT 适配路径的流程编排与分发上下文。orchestrator 委派本 skill（`msmodelslim-model-adapt`）且分析结论为 `model_family ∈ dit` 时，按本文档执行（**不进入 LLM/VLM 主流程**）；分析结论由 `msmodelslim-model-analysis` 回传的 `model_family` / `implementation_source` / `inference_repo` 与分析报告给出。
>
> **实现细节不在本文**：目录结构、模板、11 接口、注册、checklist 全部见 [`implementation_guide.md`](implementation_guide.md)（单一实现入口）；架构决策与陷阱见 [`architecture_patterns.md`](architecture_patterns.md) / [`pitfalls.md`](pitfalls.md)；四步验证完整命令见 `msmodelslim-adapter-verification/references/verification_guide.md`。

## 适用与不适用

- **适用**：`model_family = dit` 的扩散/多模态生成模型；典型如 HunyuanVideo、Wan2.2-T2V/I2V/TI2V、FLUX.1-dev（已迁移）、Stable Diffusion 3、Sana、HunyuanDiT、CogViewX、SD1.5/SDXL。统一重构路径 `MultimodalPipelineInterface`（不保留 Legacy），参考实现 `msmodelslim/model/hunyuan_video/model_adapter.py::HunyuanVideoModelAdapter`。
- **不适用**：
  - Decoder-only LLM / 理解类 VLM（走 LLM/VLM 主流程，orchestrator 直接委派 `msmodelslim-model-adapt`）
  - Encoder-only 模型
  - 敏感层分析、摸高、二分搜索等精度调优能力（经验库 L2 §7 + 直调 `apply_rollback.py` 在适配产物上接力）

## 上下文输入（分析阶段已获得，适配阶段直接复用）

| 参数 | 必填 | 说明 |
|------|------|------|
| `model_type` | ✅ | msModelSlim 注册名，如 `HunyuanVideo`、`Wan2.2-T2V-A14B`、`Wan2.2-I2V-A14B`、`Sana`；先前以 `flux1` / `wan2_1` 注册的 model_type 在本项目中按重构路径对待 |
| `model_path` | ✅ | 模型权重目录（diffusers 标准布局，含 `model_index.json`） |
| `inference_repo` | ✅ | 扩散模型推理仓路径；与权重目录**互不包含**；仅做"路径存在且为目录"校验 |
| `save_path` | ✅ | 适配工作目录 |
| `trust_remote_code` | | 默认 `true` |

> 前置校验（失败即中止，回传 `status: failed`）：
> - `model_family` 不是 `dit` 时**不得进入本路径**（避免误用 LLM 模板）。
> - 未提供 `inference_repo` 或路径不存在 → 立即中止并提示用户重新提供；不进行自动猜测。

> NPU 执行约定：`--device` 仅接受字面量 `npu`；具体物理卡号通过 `ASCEND_RT_VISIBLE_DEVICES=<idx>` 环境变量指定（不要传 `npu:0` / `npu:x` 等带卡号形式）。

## 工作流概览（分析判定 dit 之后继续）

```
┌────────────────────────────────────────────┐
│ 1. 适配器生成                               │
│    按 implementation_guide.md 执行：        │
│    子架构判断 → 模板选择 → 11 接口实现       │
│    → config.ini 注册 → bash install.sh      │
└──────────┬─────────────────────────────────┘
           ▼
┌────────────────────────────────────────────┐
│ 2. 四步验证                                 │
│    委派 msmodelslim-adapter-verification；  │
│    DiT 必加 flag 见 implementation_guide §8 │
│    step1 路径校验（强制 skip，零拷贝）       │
│    step2 全回退量化 → step3 权重一致性       │
│    → step4 实际量化与描述文件规则校验        │
└──────────┬─────────────────────────────────┘
           ▼
┌────────────────────────────────────────────┐
│ 3. 输出                                     │
│    四步全 passed → 回传成功信封             │
│    （adapter_registered=true + 四步         │
│    verification_steps + artifact_paths，    │
│    见 prepare_model.md「Agent:              │
│    msmodelslim-model-adapt」）              │
│    任一失败 → 失败信封（status: failed）    │
│    orchestrator 收到成功信封后委派          │
│    quant-tuning-quantize-dit                │
└────────────────────────────────────────────┘
```

### step1 skip 模式为什么零拷贝

Wan2.2-T2V-A14B 等大型 DiT 模型动辄几十 GB；"复制一份"既拖慢验证、又占双倍磁盘、还给"半截复制失败"留了失败面。step1 skip 模式只做"该路径对下游工具栈可读"的预检，step2 原地读、step3 原地做对比（`--reference-weights <model_path>` 显式指原始权重，因为 step1 没产生基线副本），全程零拷贝。

## DiT 专属错误

| 错误 | 处理 |
|------|------|
| 四步验证任一步 `passed=false` | 立即中止，回传 `status: failed` 与失败步骤 |
| `msmodelslim quant` 加载适配器失败 | 立即中止，回传 `status: failed`，由 orchestrator 决策 |
| 双专家 `calib_data` key 与 `init_model` 返回 dict key 不一致 | 量化服务 fail-fast 抛 `SchemaValidateError`；立即中止并提示 |

## 关键约束（流程侧；实现侧约束见 implementation_guide §6）

- **本阶段不直接消费 `calibration_dataset` / `smooth` / `quarot` 等参数**：如需引入激活校准集或抑制策略，由经验库 L2 §7 + 直调 `apply_rollback.py` 在 YAML / process 步上叠加后再回到 `quant-tuning-quantize-dit`
- **不修改 LLM/VLM skill 既有行为字段**
- **`inference_repo` 内的 `modeling_*.py` / `pipeline/*.py` 是适配器生成的必读输入**，必须阅读以对齐 forward 签名与 block 顺序
- **YAML `apiversion` 固定 `multimodal_sd_modelslim_v1`**：与 LLM/VLM 的 `modelslim_v1` 区分；YAML 顶层除 `apiversion` / `metadata` / `spec` 外禁止额外字段，`model_family` / `inference_repo` 通过 subagent_io 协议字段传递
- **`init_model` 必须返回 `Dict[str, nn.Module]`**：`calib_data` key 须一一对应
- **`InferenceConfig` 字段名必须与目标推理仓的 `parse_args` argparse key 一一对应**：字段映射见 [`inference_config_field_map.md`](inference_config_field_map.md)

## 参见

- [实现指南（单一实现入口）](implementation_guide.md)
- [架构模式](architecture_patterns.md) / [陷阱清单](pitfalls.md) / [推理配置字段映射](inference_config_field_map.md)
- 四步验证：`msmodelslim-adapter-verification/references/verification_guide.md`
- 回传信封：`quantization-accuracy-tuning-orchestrator/references/prepare_model.md`「Agent: msmodelslim-model-adapt」与 [subagent_io_protocol.md](../../../quantization-accuracy-tuning-orchestrator/references/subagent_io_protocol.md)
- 官方文档：[多模态生成接入指南](https://gitcode.com/Ascend/msmodelslim/blob/master/docs/zh/knowledge_base/model/integrating_multimodal_generation_model.md)
