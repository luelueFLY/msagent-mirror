# 校准数据（`spec.dataset`）— DiT

## 为什么必须写 `spec.dataset`

`MultimodalSDServiceConfig.dataset` 的 Pydantic 默认值是 **`mix_calib.jsonl`**
（`msmodelslim/core/quant_service/multimodal_sd_v1/quant_config.py`）。
`mix_calib.jsonl` 是 LLM 文本校准集，每条只有 `inputs_pretokenized`，**没有 `text` 字段**，
会在 `handle_dataset` → `validate_calib_samples` 处 fail-fast：

```
Provide text in dataset entries (index.jsonl / VlmCalibSample.text).
```

所以**不写 `dataset` 不等于 data-free**，只是静默落到一个错误的默认值。
DiT 的 "data-free" 指的是：**不引入外部激活校准数据**，只用一组 prompt 触发模型
自身浮点推理（`inference_dump_calib_data`）产 calib_data。prompt 本身仍然要给。

## 短名 → `msmodelslim/lab_calib/` 现成 prompt 集

`dataset` 可写短名（在 `lab_calib/` 下解析）、绝对路径或相对路径。
现成的 DiT prompt 集：

| 短名 | 场景 | 内容 |
|------|------|------|
| `wan2_2_t2v` | Wan2.2-T2V-A14B | 1 条 `text` |
| `wan2_2_i2v` | Wan2.2-I2V-A14B | 1 条 `text` + `image`（`i2v_input.JPG`） |
| `wan2_2_ti2v` | Wan2.2-TI2V-5B | 1 条 `text` |
| `hunyuanvideo` | HunyuanVideo | 1 条 `text` |

YAML 里直接：

```yaml
spec:
  dataset: wan2_2_t2v
```

## 自建校准集：`index.jsonl` 模板

目录里放**一个** `index.json` 或 `index.jsonl`（两者同时存在会报错），
多模态资源与该文件同目录、按**相对路径**引用：

```
my_calib/
├── index.jsonl
└── i2v_input.JPG        # 仅 I2V 等需要图像输入的场景
```

`index.jsonl` 每行一个 JSON 对象，**至少含非空 `text`**：

```jsonl
{"text": "A stylish woman walks down a Tokyo street filled with warm glowing neon ..."}
{"text": "Summer beach vacation style, a white cat wearing sunglasses sits on a surfboard ..."}
```

可直接复制 [`index.example.jsonl`](index.example.jsonl)（取自 `lab_calib/wan2_2_t2v/index.jsonl`）。

I2V / 图生视频场景追加 `image`（相对 `index.jsonl` 所在目录）：

```jsonl
{"text": "Summer beach vacation style, a white cat wearing sunglasses ...", "image": "i2v_input.JPG"}
```

字段约定（`VlmCalibSample`）：`text` 必填；`image` / `audio` / `video` 按模型输入模态提供，
缺项样本会被跳过。

然后：

```yaml
spec:
  dataset: /abs/path/to/my_calib          # 或 /abs/path/to/my_calib/index.jsonl
```

## 参考

- `msmodelslim/lab_calib/wan2_2_t2v/index.jsonl`
- `msmodelslim/lab_practice/hunyuan_video/hunyuan_video_w8a8f8_mxfp.yaml`（`dataset: hunyuanvideo`）
- `msmodelslim/docs/zh/user_guide/usage_quick_quantization.md#dataset---校准数据路径配置`
- 完整 YAML 配置示例见 [`w8a8_dynamic.example.yaml`](w8a8_dynamic.example.yaml)
