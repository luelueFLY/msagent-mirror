# DiT 验证模板

`apiversion: multimodal_sd_modelslim_v1`。供 `scripts/step2_run_quantization_dit.py`（step2 全回退）与 step4（实际量化）使用。

| 文件 | 用途 | 关键差异 |
|---|---|---|
| `fallback_config.yaml` | step2 全回退 | `exclude: ["*"]` |
| `w8a8_dynamic_full_model.yaml` | step4 W8A8 动态 | `dtype: int8`、`enable_dump: false`（data-free） |
| `w8a8_mxfp8_full_model.yaml` | step4 W8A8 MXFP8 | `dtype: mxfp8`、per_block、`enable_dump: false`（data-free） |
| `index.example.jsonl` | 自建校准集样例 | step2 缺省时落到 `<output-path>/calib_data/index.jsonl` |

> 不提供 `w8a8_static_full_model.yaml` —— DiT 阶段默认 W8A8 动态量化（见 `quant-tuning-quantize-dit/SKILL.md`）。

---

## 三条硬约束

### 1. `spec.dataset` 必填且必须是字符串

- 省略会触发 `validate_calib_samples` 的 `requires non-empty text` fail-fast；写成字典会触发 Pydantic 的 `Input should be a valid string`。

**三种可用形态**（`VLMDatasetLoader.get_dataset_by_name` 责任链）：

| 形态 | 例子 | 命中 loader |
|---|---|---|
| `lab_calib/` 短名 | `wan2_2_t2v` | 解析为目录后走 Indexed |
| 含 `index.jsonl` 的目录绝对路径 | `/work/out/calib_data` | `IndexedDirectoryDatasetLoader` |
| `index.json` / `index.jsonl` 文件绝对路径 | `/work/out/calib_data/index.jsonl` | `JsonlDatasetLoader` |

短名清单：`hunyuanvideo` / `wan2_2_t2v` / `wan2_2_i2v`（含 `image`）/ `wan2_2_ti2v`。

**自建推荐目录形态**：目录里放一份 `index.jsonl`（文件名必须是这个，叫别的会掉到 legacy 兼容分支），每行 `{"text": "..."}`。样例见 `index.example.jsonl`。

### 2. `dump_config.enable_dump` 一律显式 `false`（DiT data-free 不 dump 校准数据）

DiT data-free 路径不 dump 校准数据：`enable_dump: false` 短路 `prepare_calib_data`（直接返回 `{expert: None}`），跳过浮点推理 dump。`true` 仅在确需浮点推理 dump 校准数据时显式开启——会触发整段无谓浮点推理，W8A8 / MXFP8 / 全回退模板一律保持 `false`。

复制模板时不要"顺手"改回 `true`，会和预检告警打架。

### 3. `inference_config` 按目标推理仓填

各仓 `InferenceConfig` 都是 `ConfigDict(extra="forbid")` 且字段集完全不同，模板不预置任何字段。**字段名以 `msmodelslim/model/<repo>/model_adapter.py` 的 `InferenceConfig` 类声明为准**（推理仓 `parse_args` 只作参考）。

完整字段表 / 默认值 / 入口脚本详见 [`inference_config_field_map.md`](../../msmodelslim-model-adapt/references/dit/inference_config_field_map.md)（统一真相源）。

> Wan2.2 是 `sample_guide_scale_low` / `sample_guide_scale_high` **两个字段**，没有 `sample_guide_scale`。

**留 `{}` 的条件**：仅 step2 全回退 + 适配器走重构路径（`MultimodalPipelineInterface`，目前是 `wan2_2` / `hunyuan_video`）。其它情况（step4、legacy 适配器 `wan2_1` / `flux1`）必须补齐。

---

## 推理仓注入

Wan 适配器从 `WAN_INFERENCE_REPO`（或 `model_path` 父目录探测 `Wan2.2/`）把推理仓插进 `sys.path`，漏了会 `ImportError: Failed to import WanModel`。由 `scripts/step2_run_quantization_dit.py --inference-repo <path>` 设好。
