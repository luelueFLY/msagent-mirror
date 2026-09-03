# AISBench-VBench 集成说明

实施级参考：错误码定义、上下游关系、KI 速查都在本文档。

## 1. 上下游关系

```
score.py (单进程入口)
  ├─ patch_config.py → 改写 AISBench 模板三处变量
  ├─ subprocess: ais_bench <patched> --mode eval
  └─ 解析 {work_dir}/results/{model_abbr}/vbench_<dim>.json
       {work_dir}/summary/summary_*.txt
                 ↓
            AISBench (上游；只读)
```

**AISBench 是只读上游**：本 Skill 不修改 `benchmark/ais_bench/` 任何文件；仅复制 `eval_vbench_standard.py` 模板并改写三个变量。

## 2. 模板补丁机制

AISBench VBench 配置是**纯 Python 模块**（被 `Config.fromfile()` 直接 import），三个变量在模块级硬编码：

```python
# benchmark/ais_bench/configs/vbench_examples/eval_vbench_standard.py
DATA_PATH = ""
VBENCH_CACHE_DIR = ""
vbench_eval_cfg = dict(
    load_ckpt_from_local=True,
    # full_json_dir: optional, default is third_party/vbench/VBench_full_info.json
)
```

`patch_config.patch_config()` 通过正则替换改写这些行，并 `ast.parse` 校验写出的文件仍能解析。补丁产物落在 `{work_dir}/vbench_inputs/eval_vbench_patched.py`。

调用：

```bash
ais_bench {work_dir}/vbench_inputs/eval_vbench_patched.py \
    --mode eval --max-num-workers <N>
```

## 3. 输出 JSON 结构

每个维度一个文件，路径 `{work_dir}/results/{model_abbr}/vbench_<dim>.json`：

```json
{
  "accuracy": 84.2,
  "details": {
    "subject_consistency": {"score": 0.842, "video_results": [...]}
  }
}
```

聚合分数写在 `{work_dir}/summary/summary_<timestamp>.txt`：

```
vbench_subject_consistency: {'accuracy': 97.05}
vbench_quality: {'accuracy': 89.55}
vbench_semantic: {'accuracy': 79.93}
vbench_total: {'accuracy': 87.63}
```

`score._load_aggregates()` 直接读这四行，**绝不本地重算**——`VBenchSummarizer` 才是 authoritative source。

## 4. 已知问题速查（KI）

### KI-001: `KeyError: 'infer_cfg'`
- **触发**：`ais_bench` 后 exit ≠ 0，stderr 含 `KeyError: 'infer_cfg'` → 错误码 `AISBENCH_INCOMPATIBLE_VERSION`。
- **根因**：pip 装的 `ais_bench` 是旧版（依赖 `data_config['infer_cfg']`），但模板是新版（pipeline-style `VBenchDataset`）。
- **修复**：`pip install -U ais_bench` 升到与 benchmark 仓一致的版本。

### KI-002: Dropbox 不可达 → RAFT `models.zip` 失败
- **触发**：`download_vbench_cache.sh` 在 RAFT 步骤报 `curl: (35) Recv failure`。
- **修复**：改用 HF 镜像 `HF_ENDPOINT=https://hf-mirror.com bash download_vbench_cache.sh`。**不自动重试**；用户授权后才触发。

### KI-003: HuggingFace 直连超时
- 同 KI-002 — 设置 `HF_ENDPOINT` 镜像。

### KI-004: Agent 跳过 Skill 直接下载
- **触发**：Orchestrator 看到默认 `~/.cache/vbench` 为空，**跳过 `score.py` 直接执行 `download_vbench_cache.sh`**。
- **修复**：`score.py` 报 `CACHE_DIR_MISSING`/`CACHE_DIR_NOT_DIR`，错误信息明确指示"先跑 `check_vbench_cache.py`"，配合 `score.py` 的 `CACHE_DIR_MISSING` 强约束（orchestrator 必须传）+ `instruction` 字段硬指令。

### KI-005: stderr 未匹配已知环境错误模式
- **触发**：`ais_bench` exit ≠ 0，stderr 不命中任何 ENV_* 模式 → 走 `AISBENCH_EXIT_NONZERO` 兜底。
- **修复**：兜底消息**始终**附官方文档 URL。

### KI-006: `inference_params` 缺失
- **触发**：`score.py` 找不到 `{infer_outputs}/run_manifest.json`，`inference_params` 字段被省略。
- **根因**：上游 `quant-tuning-evaluate` DiT 扩展节 没写 manifest（auto 模式被砍后只剩 vbench_mini，应有 manifest）；或 manifest 写盘失败。
- **修复**：
  1. 优先让 `quant-tuning-evaluate` DiT 扩展节 重新跑一遍（vbench_mini 模式会重写 manifest）；
  2. 临时从 `{output_dir}/vbench_runner.log` 的 `=== argv ===` 段反推；
  3. **不要**在 `score.py` 里写 fallback 推断 —— 错的参数比没参数更糟。
- **预期**：下游 orchestrator / history 容忍 `inference_params` 缺失（不熔断）。

## 5. 错误码速查

每个错误码都是 `msagent-io` `error.code` 的稳定字符串。

| 错误码 | 触发 | 处理建议 |
|--------|------|----------|
| `DATA_PATH_REQUIRED` / `DATA_PATH_NOT_DIR` | `--infer-outputs` 缺失或非目录 | orchestrator 必须传 |
| `FULL_JSON_REQUIRED` / `FULL_JSON_NOT_FOUND` / `FULL_JSON_SCHEMA_MISMATCH` | `--full-json-dir` 缺失/不存在/格式错 | 检查下载源是否 AISBench 出品 |
| `CACHE_DIR_MISSING` / `CACHE_DIR_NOT_DIR` | `--vbench-cache-dir` 缺失或非目录 | 跑 `check_vbench_cache.py`；**禁止默认下载** |
| `DIM_NOT_FOUND` | `--score-dimensions` 不在 AISBench 16 维列表 | 改用合法维度 |
| `ENV_DECORD_MISSING` | `ModuleNotFoundError: 'decord'` | `pip install decord`（x86_64）；ARM 源码编译 |
| `ENV_DETECTRON2_MISSING` | `ModuleNotFoundError: 'detectron2'` | `pip install -e ais_bench/third_party/detectron2 --no-build-isolation` |
| `ENV_TORCH_MISSING` | `ModuleNotFoundError: 'torch'` | 安装匹配本地 CUDA / 昇腾 toolkit 的 PyTorch |
| `ENV_TORCHVISION_MISSING` | `ModuleNotFoundError: 'torchvision'` | 匹配 PyTorch 版本 |
| `ENV_HUGGINGFACE_HUB_MISSING` | `ModuleNotFoundError: 'huggingface_hub'` | `pip install huggingface_hub` |
| `ENV_FFMPEG_MISSING` | ffmpeg not found | `apt install ffmpeg` 或 conda |
| `ENV_CUDA_MISMATCH` | `CUDA driver version is insufficient` / `libtorch_cuda` | 检查 CUDA toolkit / 驱动 / PyTorch 三方一致 |
| `ENV_CUDA_OOM` | `CUDA out of memory` | 降低 `--max-num-workers 1` 或减小视频分辨率 |
| `ENV_HF_TOKEN_MISSING` | `401` / `HF_TOKEN` | 设置 `$HF_TOKEN` 或 `huggingface-cli login` |
| `AISBENCH_INCOMPATIBLE_VERSION` | `KeyError: 'infer_cfg'` | `pip install -U ais_bench`（见 KI-001） |
| `TEMPLATE_MISMATCH` / `TEMPLATE_SYNTAX_ERROR` | patch_config 替换失败 / 写出文件无法解析 | 升级 Skill 配套模板 |
| `AISBENCH_EXIT_NONZERO` | `ais_bench` 退出码非 0（未匹配已知模式） | 始终附官方 doc URL |
| `AISBENCH_NO_OUTPUT` / `AISBENCH_MULTIPLE_MODELS` / `AISBENCH_NO_DIMENSIONS` / `AISBENCH_BAD_OUTPUT` | 结果目录异常 | 检查 ais_bench 实际运行 |
| `AISBENCH_NO_SUMMARY` / `AISBENCH_INCOMPLETE_SUMMARY` | summary 目录/字段缺失 | 同上 |
| `SUBSCORER_TIMEOUT` | ais_bench 超过 `--timeout-sec` | 重试或缩数据集 |
| `BASELINE_NOT_DIR` / `BASELINE_FAILED` / `BASELINE_SCORE_MISSING` | baseline 对比失败 | 检查 FP baseline 推理（`quant-tuning-evaluate` DiT 扩展节 跑 `--ckpt_dir` 指 FP 权重）是否成功 |

## 6. 升级 AISBench 上游时

`patch_config` 模板行格式变化是本 Skill 最大的脆弱点。一旦 AISBench 改动 `DATA_PATH = ""` 的写法，替换会失败并报 `TEMPLATE_MISMATCH`。

升级步骤：
1. 同步 AISBench 版本（建议固定 `benchmark/ais_bench/` 子模块 commit hash）。
2. 手动对照 `ais_bench/configs/vbench_examples/eval_vbench_standard.py`，确认三处替换行仍存在。
3. 如正则不再匹配，扩展 `patch_config.py` 的 pattern。
4. 跑 §7 的烟雾测试。

## 7. 烟雾测试

```bash
# 准备 2-3 条测试视频
mkdir -p /tmp/smoke/subject_consistency
cp <某 mp4> /tmp/smoke/subject_consistency/0000.mp4

# 先跑 precheck（确认 vbench 缓存路径）
python scripts/check_vbench_cache.py

# 评分（用用户确认的 cache 路径）
python scripts/score.py \
    --infer-outputs /tmp/smoke \
    --full-json-dir <VBench_kmeans_info*.json> \
    --vbench-cache-dir <用户确认的路径> \
    --work-dir /tmp/smoke/work
```

期望输出包含 `ok: true`、`scores.<dim>`、`overall_score`。