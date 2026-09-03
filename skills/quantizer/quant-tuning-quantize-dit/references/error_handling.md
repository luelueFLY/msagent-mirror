# DiT 量化错误处理参考

> 本文件是 `subagent_io_protocol.md` 失败信封的 DIT 量化特化（error.code 枚举与建议），
> 信封格式以协议为准。

## 错误上报格式（对齐 MSAGENT_IO v1 失败信封）

发生错误时，按 `msagent.subagent_io` 协议立即中止并回传（`status: "failed"` 时填 `error`，不填 `output`）：

```json
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "quant-tuning-quantize-dit",
  "status": "failed",
  "error": {
    "code": "QUANTIZE_ERROR",
    "message": "msmodelslim quant 执行失败摘要（stderr 关键行）",
    "suggestion": "建议的解决方式，见下方 code 枚举表"
  }
}
```

- `code` / `message` 为协议标准字段，orchestrator 据此解析失败原因
- `suggestion` 为本 skill 扩展字段，供 orchestrator 决策参考

**不续跑其它命令，不伪造输出。**

## error.code 枚举表

| code | 含义 | 典型场景 | suggestion |
|------------|------|----------|------------|
| `ENV_ERROR` | 环境/依赖未就绪 | msmodelslim 未安装；PYTHONPATH 未设置 | 按 `quantization-accuracy-tuning-orchestrator/references/prepare_environment.md` 安装后重试；确认 `export PYTHONPATH=/path/to/inference_repo:$PYTHONPATH` |
| `PATH_ERROR` | 路径不存在或不可读 | `model_path` / `adapter_path` / `inference_repo` / `output_dir` 不存在 | 检查路径后重试或中止 |
| `CONFIG_ERROR` | YAML 配置校验失败 | `apiversion` 不是 `multimodal_sd_modelslim_v1`；`quant_type` 值非法；YAML 顶层含额外字段 | 改用 DiT YAML 模板（INT8：`assets/w8a8_dynamic.example.yaml`；MXFP8：`assets/w8a8_mxfp8.example.yaml`）；此类配置性错误立即中止，不重试 |
| `DATASET_ERROR` | 校准数据问题 | 漏写 `spec.dataset` 落到默认 `mix_calib.jsonl`；`index.jsonl` 缺少非空 `text`；I2V `image` 路径不可解析 | 在 YAML 显式写 `spec.dataset`（如 `wan2_2_t2v`）；见 `assets/calib_dataset.md` |
| `OOM_ERROR` | 设备内存不足 | Ascend OOM | 换设备或减小输入尺寸 |
| `ADAPTER_ERROR` | 适配器注册/forward 不匹配 | `Adapter not registered: HunyuanVideo`；round-trip `shape mismatch` | 前者见 `msmodelslim-model-adapt/references/registration_guide.md`；后者检查 `handle_dataset` 输出字段是否对齐 forward |
| `EXPERT_CONFIG_ERROR` | 双 expert 配置不一致 | `calib_data missing for expert 'low_noise_model'`（`calib_data` key 与 `init_model` 返回 dict key 不一致） | 检查 `init_model` 返回 dict 与 `prepare_calib_data`；立即中止 |
| `QUANTIZE_ERROR` | 量化命令执行失败 | `msmodelslim quant` 非零退出 | 报 stderr 摘要，等待 orchestrator 决策 |
| `ROUND_TRIP_ERROR` | round-trip 检查失败 | 量化后权重 save/load round-trip 验证失败 | 报 stderr 摘要，标记 `round_trip_check: failed`，回传失败 |
| `UNKNOWN_ERROR` | 未归类异常 | 上述之外的错误 | 寻求上层 Agent（orchestrator）解决 |

## 处理原则

- **错误即停**：命令失败后立即中止，不兜底续跑
- **先自查再上报**：错误命中本表时先按 `suggestion` 自查；若多次解决后依然未解决，按上述失败信封携带 `code` + `message` + `suggestion` 回传 orchestrator 决策
- **配置性错误不重试**：`CONFIG_ERROR`（apiversion / quant_type 不符）属于协议性防呆，重试无意义，直接中止
- **等待决策**：`QUANTIZE_ERROR` / `ROUND_TRIP_ERROR` 等运行时错误上报后等待 orchestrator 决策，不自行换方案
