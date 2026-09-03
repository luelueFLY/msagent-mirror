# DiT 推理仓 InferenceConfig 字段速查表

> **单一真相源**。所有 SKILL.md / YAML 模板中关于"按目标 DiT 推理仓的 argparse 命名差异"的内容均以本表为准，重复列表请改成本文件引用。

## 1. 字段映射（字段名按推理仓）

| 推理仓 | InferenceConfig 字段集 | 入口脚本 |
|---|---|---|
| **HunyuanVideo** | `model_resolution` / `video_size` / `video_length` / `infer_steps` / `seed` / `neg_prompt` / `cfg_scale` / `embedded_cfg_scale` / `num_videos` / `flow_shift` / `batch_size` | `sample_video.py` |
| **Wan2.2** (T2V/I2V/TI2V) | `task` / `convert_model_dtype` / `size` / `frame_num` / `sample_steps` / `sample_shift` / `sample_guide_scale_low` / `sample_guide_scale_high` / `base_seed` / `prompt` / `neg_prompt` / `offload_model` / `ulysses_size` / `ring_size` / `cfg_size` / `t5_cpu` / `dit_fsdp` / `t5_fsdp` / `vae_parallel` | `generate.py` |
| **Wan2.1** (legacy) | `sample_steps` / `sample_guide_scale` / `sample_shift` / `frame_num` / `size` / `base_seed` | `generate.py` |
| **FLUX.1-dev** | `num_inference_steps` / `guidance_scale` / `height` / `width` / `negative_prompt` | `inference_flux.py` |
| **SD3 / SDXL** | `num_inference_steps` / `guidance_scale` | (diffusers 默认) |

> **Wan2.2 特例**：双专家模型用 `sample_guide_scale_low` / `sample_guide_scale_high` **两个字段**（不是 `sample_guide_scale`），两者独立。

## 2. 默认值（按推理仓）

| 推理仓 | 字段默认值 |
|---|---|
| HunyuanVideo | `infer_steps=50` / `cfg_scale=1.0` / `embedded_cfg_scale=6.0` / `flow_shift=7.0` / `model_resolution=720p` / `video_size=[720,1280]` / `video_length=129` |
| Wan2.1 t2v-14B | `sample_steps=50` / `sample_guide_scale=7.5` / `sample_shift=5.0` / `frame_num=81` / `size=720*1280` |
| Wan2.2-T2V-A14B | `sample_steps=27` / `sample_guide_scale_low=5.0` / `sample_guide_scale_high=5.0` / `sample_shift=5.0` |
| Wan2.2-I2V-A14B | `sample_steps=40` / `sample_guide_scale_low=5.0` / `sample_guide_scale_high=5.0` |
| FLUX.1-dev | `num_inference_steps=20` / `guidance_scale=3.5` / `height=1024` / `width=1024` |
| SD3 / SDXL | `num_inference_steps=30` / `guidance_scale=7.5` |

## 3. 定位方法（增 / 改 DiT 适配器时）

1. 在 `<inference_repo>/README.md` 推理示例命令中找到入口脚本（`generate.py` / `sample_video.py` / `inference_flux.py` 等）。
2. 在 `<repo>/config.py` / `<repo>/hyvideo/config.py` 等位置找 `parse_args`，其 `--<key>` 列表即为该推理仓的 InferenceConfig 字段白名单。
3. **字段名以 `msmodelslim/model/<repo>/model_adapter.py` 的 `InferenceConfig` 类声明为准**（推理仓 `parse_args` 只作参考）。

> **禁止**用通用名（如 `num_inference_steps`）硬编码——除非目标推理仓 argparse 确实叫这名。
