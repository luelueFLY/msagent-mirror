---
name: quant-tuning-quantize-dit
description: 对 DiT（扩散/多模态生成）模型执行 W8A8 动态（data-free）或 W8A8 MXFP8（data-free）量化。覆盖 HunyuanVideo、Wan2.2-T2V/I2V/TI2V、FLUX.1-dev（已迁移）、SD3、Sana、HunyuanDiT、CogViewX 等。YAML apiversion 固定 multimodal_sd_modelslim_v1，统一 MultimodalPipelineInterface 重构路径（不再保留 LegacyMultimodalPipelineInterface）。模板与字段以 msmodelslim/model/hunyuan_video/model_adapter.py（唯一已迁移到重构路径且 lab_practice YAML 已 validated 的 DiT）为参考；其它 DiT 需按各自推理仓的 `parse_args` 调整字段集合。data-free 指不引入外部激活校准数据，spec.dataset（校准集短名，短名如 wan2_2_t2v；enable_dump: false 时不参与 dump）仍必填；精度调优通过下游经验库 L2 §7 + 直接调 `quantization-expert-experience-tuning-rules/scripts/apply_rollback.py`（整层回退）扩展 exclude 列表，闭环由 `quantization-accuracy-tuning-orchestrator` 调度。
license: Apache-2.0
metadata:
  version: 0.1.0
  domain: quantization
  framework: msmodelslim
  protocol: cli
  skill_class: tool
  aliases:
    - dit-quantizer
    - w8a8-dit
  trigger_intents:
    - DiT 量化
    - 扩散模型量化
    - 量化 FLUX
    - 量化 SD3
  keywords:
    - msmodelslim quant
    - w8a8
    - w8a8_dynamic
    - w8a8_mxfp8
    - multimodal_sd_modelslim_v1
    - dit
    - diffusion
    - flux
---

# Skill: DiT 量化（W8A8 动态 / MXFP8）

## 解决什么

依据 Practice YAML（`apiversion: multimodal_sd_modelslim_v1`），调用 `msmodelslim quant` 对 DiT 模型执行 **W8A8 动态（data-free）** 或 **W8A8 MXFP8（data-free）** 量化；走 `MultimodalPipelineInterface` 重构路径。

## 不解决什么

- **本 skill 不做敏感层分析 / 摸高 / 二分**：那些能力由 `msmodelslim-model-adapt`（DiT 扩展节）+ 经验库 L2 §7 + 直接调 `apply_rollback.py` 接力；本 skill 只负责按最终 Practice YAML 执行量化
- **本 skill 不消费抑制策略参数**：本阶段不直接接受 `smooth` / `quarot` / `iter_smooth` / `flex_smooth_quant` / `awq` 等；如需引入，由下游 practice 子能力补齐 YAML 字段后再回到本 skill 重新执行
- **不替代 LLM 量化路径**：本 skill 仅服务 `model_family ∈ dit`

> `spec.dataset`（校准集短名；`enable_dump: false` 时不参与 dump，仅作回退/复现用）**不在**此列 —— 它是必填项，见「校准数据 `spec.dataset`」。

## 协作关系

```
quantization-accuracy-tuning-orchestrator (workflow)
        │  按 model_family 路由到 dit 分支
        ▼ 调用
quant-tuning-quantize-dit (tool)
        │
        ▼ MultimodalSDModelslimV1QuantService
  MultimodalPipelineInterface（重构路径）
        │
        ▼ CLI
  msmodelslim quant
        │
        ▼ 输出（MindIE-SD 格式）
  {workdir}/round_1/quantized/
```

## 输入参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `model_path` | string | ✅ | 原始 DiT 权重目录（diffusers 标准布局） |
| `adapter_path` | string | ✅ | DiT 适配器 `.py`（来自 `msmodelslim-model-adapt` 的 DiT 扩展节） |
| `output_dir` | string | ✅ | 量化产物保存路径；推荐 `{workdir}/round_1/quantized/` |
| `model_type` | string | ✅ | msModelSlim 注册名（如 `HunyuanVideo`、`Wan2.2-T2V-A14B`、`Wan2.2-I2V-A14B`、`Sana`）；先前以 `flux1` / `wan2_1` 注册的 model_type 在本项目中按重构路径对待 |
| `device` | string | ✅ | 设备类型；**必须传 `npu`**（不要传 `npu:0` / `npu:x` 等带卡号的形式）；具体卡号通过环境变量 `ASCEND_RT_VISIBLE_DEVICES` 指定，例如 `export ASCEND_RT_VISIBLE_DEVICES=0` |
| `trust_remote_code` | bool | | 默认 `true` |
| `inference_repo` | string | | 推理仓路径（若 adapter 需要注入 sys.path）；需确保该路径已加入 PYTHONPATH，e.g. `export PYTHONPATH=/path/to/hunyuan_video:$PYTHONPATH` |
| `calib_dataset` | string | | 写入 YAML `spec.dataset` 的短名或路径；默认按 `model_type` 取 `lab_calib` 现成 prompt 集（见「校准数据 `spec.dataset`」） |

> **本阶段不直接消费**：`smooth`、`quarot`、`iter_smooth`、`flex_smooth_quant`、`awq`、`kv_quant` 等抑制策略参数。这些策略的字段变更由 orchestrator 直接调 `quantization-expert-experience-tuning-rules/scripts/apply_rollback.py`（整层回退）在 YAML 上叠加 exclude 后再回到本 skill 执行量化。

## CLI 调用

### 方式一：使用 Practice YAML（推荐）

```bash
ASCEND_RT_VISIBLE_DEVICES=0 msmodelslim quant \
  --model_path "${MODEL_PATH}" \
  --config_path "${WORKDIR}/practice.yaml" \
  --save_path "${OUTPUT_DIR}" \
  --device npu \
  --model_type "${MODEL_TYPE}" \
  --trust_remote_code True
```

> `--device` 仅接受字面量 `npu`；不要传 `npu:0` / `npu:x` 等带卡号的形式。卡号一律通过 `ASCEND_RT_VISIBLE_DEVICES` 环境变量指定（如 `ASCEND_RT_VISIBLE_DEVICES=0,1` 多卡）。

YAML `apiversion` 固定为 `multimodal_sd_modelslim_v1`，模板见 `assets/w8a8_dynamic.example.yaml`。

> 量化方案由 Practice YAML（`--config_path`）给定，不使用 `--quant_type`（与非 DIT 的 `quant-tuning-quantize` 口径一致：`--config_path` 与 `--quant_type` 互斥）。

## 量化方案细节

- **权重**：per-channel INT8 / per-block MXFP8
- **激活**：动态量化 per-token INT8 / per-block MXFP8
- **不引入外部激活校准数据**：data-free 指不引入激活校准集；**`spec.dataset` 仍必须显式写**（省略会落到默认 `mix_calib.jsonl` 并失败；`enable_dump: false` 时该集不参与 dump，仅作回退/复现用）
- **dynamic 量化需 `enable_dump: false`**：DiT data-free 路径不 dump 校准数据，`enable_dump: false` 短路 `prepare_calib_data`、避免无谓浮点推理；`true` 仅在确需浮点推理 dump 校准数据时显式开启（见 `msmodelslim-adapter-verification/references/dit/README.md` 硬约束 #2）
- **不直接消费抑制策略**：`smooth` / `quarot` / `iter_smooth` / `flex_smooth_quant` / `awq` 等字段不在本 skill CLI 暴露；如需引入，由 orchestrator 直接调 `quantization-expert-experience-tuning-rules/scripts/apply_rollback.py`（整层回退）在 YAML 上补齐 `spec.process` / `spec.algorithm_config` 后再回到本 skill 重新执行

对称 / 非对称：模板已显式固化 `symmetric: true`（minmax）；如需非对称，先确认 msmodelslim 默认值再修改模板。

## 校准数据 `spec.dataset`（必填）

`MultimodalSDServiceConfig.dataset` 的 Pydantic 默认值是 `mix_calib.jsonl` —— LLM 文本校准集，每条只有 `inputs_pretokenized`、无 `text`，会在 `handle_dataset` → `validate_calib_samples` 处 fail-fast（`Provide text in dataset entries`）。**省略 `dataset` 不等于 data-free，只是静默落到一个错误的默认值。**

短名在 `msmodelslim/lab_calib/` 下解析，现成 prompt 集：

| 短名 | 场景 | 内容 |
|------|------|------|
| `hunyuanvideo` | HunyuanVideo | `text` |
| `wan2_2_t2v` | Wan2.2-T2V-A14B | `text` |
| `wan2_2_i2v` | Wan2.2-I2V-A14B | `text` + `image`（`i2v_input.JPG`） |
| `wan2_2_ti2v` | Wan2.2-TI2V-5B | `text` |

自建校准集：目录内放**一个** `index.jsonl`，每行一个 JSON 对象、至少含非空 `text`；I2V 等场景追加 `image`（相对 `index.jsonl` 所在目录）。模板见 [`assets/index.example.jsonl`](assets/index.example.jsonl)，完整说明见 [`assets/calib_dataset.md`](assets/calib_dataset.md)。

```yaml
spec:
  dataset: wan2_2_t2v                     # 或 /abs/path/to/my_calib/index.jsonl
```

## YAML 模板要点

`spec.multimodal_sd_config` 使用 `inference_config`（Pydantic 校验，与原推理仓 CLI 对齐）：

| 字段 | 值 |
|------|------|
| `dump_config.enable_dump` | `false`（DiT data-free 不 dump 校准数据，短路 `prepare_calib_data`；勿设 `true` 触发无谓浮点推理） |
| `dump_config.capture_mode` | `"args"` |
| `dump_config.dump_data_dir` | `""`（留空 → 默认 save_path） |
| `inference_config` | Pydantic `BaseModel` 子类字段（**字段名必须与目标推理仓 `parse_args` argparse key 一一对应**） |

**关键约束**：

- **dynamic 量化需 `enable_dump: false`**：DiT data-free 路径不 dump 校准数据，短路 `prepare_calib_data`、避免无谓浮点推理；`true` 仅在确需浮点推理 dump 校准数据时显式开启（详见 `msmodelslim-adapter-verification/references/dit/README.md` 硬约束 #2）。
- **必须显式写 `spec.dataset`**（短名 / 绝对路径），省略会落到默认 `mix_calib.jsonl` 并失败，见上节。
- `spec.process` 本阶段仅触发 `linear_quant`；`spec.save` 默认 `mindie_format_saver`。
- **YAML 顶层除 `apiversion` / `metadata` / `spec` 外禁止额外字段**：`model_family` / `inference_repo` 通过 subagent_io 协议字段传递，不写入量化 YAML。
- INT8 动态量化推荐 `act.scope: "per_token"` / `weight.scope: "per_channel"`；**不要**用 `per_block`（那是 mxfp8 配置）。
- **`inference_config` 字段名按目标 DiT 推理仓的 argparse 命名差异较大**：详见 [`inference_config_field_map.md`](../msmodelslim-model-adapt/references/dit/inference_config_field_map.md)（统一字段表 + 默认值 + 入口脚本 + 定位方法）。
  - **推理入口脚本名因仓而异**（Wan 系 `generate.py`、FLUX `inference_flux.py`、HunyuanVideo `sample_video.py`）；定位方法：在 `inference_repo` 的 `README.md` 找推理示例命令，再到 `<repo>/config.py` / `<repo>/hyvideo/config.py` 找 `parse_args` 的 `--<key>` 列表
- 模板见 `assets/w8a8_dynamic.example.yaml`（以 HunyuanVideo 为参考）。

## save_path 命名

- 与 LLM 路径一致：`{workdir}/round_{N}/quantized`（`N` 为调优轮次，DiT 阶段通常固定为 1）
- 权重目录为 **MindIE-SD 格式**（与 LLM/VLM 不同），可被 `msmodelslim` CLI 正常加载（save/load round-trip）

## 输出结果

### 成功

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "quant-tuning-quantize-dit",
  "status": "ok",
  "output": {
    "success": true,
    "quantized_path": "<workdir>/round_1/quantized",
    "save_format": "mindie_format_saver",
    "apiversion": "multimodal_sd_modelslim_v1",
    "exit_code": 0,
    "duration_sec": 123.4,
    "round_trip_check": "passed",
    "commands": [
      {
        "name": "quantize",
        "command": "msmodelslim quant --model_path ... --config_path ... --model_type HunyuanVideo ..."
      },
      {
        "name": "round_trip_check",
        "command": "msmodelslim quant --model_path <quantized_path> --config_path <practice.yaml> --save_path /tmp/rt_check"
      }
    ]
  }
}
```

### 失败

立即中止，回传：

```msagent-io v1
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "quant-tuning-quantize-dit",
  "status": "failed",
  "error": {
    "code": "QUANTIZE_ERROR",
    "message": "msmodelslim quant 执行失败摘要",
    "suggestion": "报 stderr 摘要，等待 orchestrator 决策"
  }
}
```

**不续跑其它命令，不伪造输出**。

失败信封格式与 `subagent_io_protocol.md` 一致（`error.code` + `error.message`）；`code` 枚举、各场景的 `suggestion` 及处理原则见 [`references/error_handling.md`](references/error_handling.md)。

## 错误处理

| 错误现象 | `error.code` | 处理 |
|----------|--------------|------|
| msmodelslim 未安装 / PYTHONPATH 未设置 | `ENV_ERROR` | 按 `quantization-accuracy-tuning-orchestrator/references/prepare_environment.md` 安装后重试 |
| `model_path` / `adapter_path` / `inference_repo` 不存在或未加入 PYTHONPATH | `PATH_ERROR` | 检查路径 / `export PYTHONPATH=...` 后重试或中止 |
| 误传 `--quant_type` 或 `--quant_type` 值非法；YAML `apiversion` 不是 `multimodal_sd_modelslim_v1` | `CONFIG_ERROR` | 立即中止（防止误用其它方案 / LLM·VLM YAML），不重试 |
| `Adapter not registered: <model_type>` | `ADAPTER_ERROR` | 见 `msmodelslim-model-adapt/references/registration_guide.md` |
| `Round-trip failed: shape mismatch` | `ADAPTER_ERROR` | 检查 `handle_dataset` 输出字段是否对齐 forward |
| `out of memory` | `OOM_ERROR` | 换设备或减小输入尺寸 |
| `Provide text in dataset entries`（漏写 `spec.dataset` 落到默认 `mix_calib.jsonl`） | `DATASET_ERROR` | YAML 显式写 `spec.dataset`（如 `wan2_2_t2v`） |
| `calib_data missing for expert 'low_noise_model'` | `EXPERT_CONFIG_ERROR` | 检查 `init_model` 返回 dict 与 `prepare_calib_data`；立即中止 |
| 量化命令非零退出 | `QUANTIZE_ERROR` | 报 stderr 摘要，等待 orchestrator 决策 |
| round-trip 校验失败 | `ROUND_TRIP_ERROR` | 报 stderr 摘要，标记 `round_trip_check: failed`，回传失败 |

> 各 `code` 的典型场景、`suggestion` 与处理原则详见 [`references/error_handling.md`](references/error_handling.md)。未命中本表或多次解决仍失败时，按失败信封（`code` + `message` + `suggestion`）回传 orchestrator。

## 磁盘管理

- 量化产物写入 `output_dir`
- 由 orchestrator 管理磁盘空间（最多保留 2 份权重）
- 本 skill 不主动清理历史产物

## 约束

- **错误即停**：命令失败后立即中止，不兜底续跑
- **单轮单次**：每次调用只执行一次量化
- **YAML `apiversion` 固定 `multimodal_sd_modelslim_v1`**
- **量化方案由 YAML 给定**：Practice YAML 模板即动态配置；`--config_path` 与 `--quant_type` 互斥，不使用 `--quant_type`
- **save_path 命名**：每轮使用 `{workdir}/round_{N}/quantized`
- **device**：`--device` 仅接受字面量 `npu`（不要传 `npu:0` / `npu:x`）；卡号一律通过 `ASCEND_RT_VISIBLE_DEVICES` 环境变量指定，优先使用单卡（如 `export ASCEND_RT_VISIBLE_DEVICES=0`）

## 检查清单

- [ ] `model_path` 存在且含 `model_index.json`（diffusers 布局）
- [ ] `adapter_path` 存在且 `model_family` 为 `dit`
- [ ] YAML `apiversion: multimodal_sd_modelslim_v1`
- [ ] YAML **显式写** `spec.dataset`（短名 `hunyuanvideo` / `wan2_2_t2v` / `wan2_2_i2v` / `wan2_2_ti2v`，或含 `index.jsonl` 的绝对路径）；**不要省略**（省略 → 默认 `mix_calib.jsonl` → 失败）
- [ ] 自建校准集时 `index.jsonl` 每行含非空 `text`；I2V 场景含 `image` 且相对路径可解析
- [ ] YAML `dump_config.enable_dump: false`（DiT data-free 不 dump 校准数据；`true` 仅在确需浮点推理 dump 时显式开启）
- [ ] YAML 顶层除 `apiversion` / `metadata` / `spec` 外无额外字段
- [ ] YAML `act.scope` 与 `dtype` 匹配: `dtype=int8` → `scope=per_token`, `dtype=mxfp8` → `scope=per_block`
- [ ] YAML `weight.scope` 与 `dtype` 匹配: `dtype=int8` → `scope=per_channel`, `dtype=mxfp8` → `scope=per_block`
- [ ] `--device npu`（不带卡号）；卡号通过 `ASCEND_RT_VISIBLE_DEVICES` 环境变量指定，优先使用单卡（如 `ASCEND_RT_VISIBLE_DEVICES=0`）
- [ ] `save_path` 为 `{workdir}/round_1/quantized` 形式且磁盘空间充足
- [ ] `msmodelslim quant --help` 可正常执行
- [ ] 未直接传 `smooth` / `quarot` / `awq` 等抑制策略参数；若需引入，由 orchestrator 直接调 `quantization-expert-experience-tuning-rules/scripts/apply_rollback.py`（整层回退）在 YAML 上叠加再回到本 skill 执行

## 参考

- [错误处理与上报格式](references/error_handling.md)
- [W8A8 动态量化 YAML 示例（INT8）](assets/w8a8_dynamic.example.yaml)
- [W8A8 MXFP8 量化 YAML 示例](assets/w8a8_mxfp8.example.yaml)
- [校准数据 `spec.dataset` 说明](assets/calib_dataset.md)
- [`index.jsonl` 模板](assets/index.example.jsonl)
- [DiT 适配器模板](../msmodelslim-model-adapt/assets/dit_model_adapter_template.py)
- 官方文档：[多模态生成接入指南](https://gitcode.com/Ascend/msmodelslim/blob/master/docs/zh/knowledge_base/model/integrating_multimodal_generation_model.md)
