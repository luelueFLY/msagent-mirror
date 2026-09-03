# DiT 评测工作流（批量推理产出 VBench 视频）

> **本文档定位**：DiT 评测路径的执行模板与分发上下文。orchestrator 委派本 skill（`quant-tuning-evaluate`）且 `model_family ∈ dit` 时，按本文档执行（**不进入 LLM/VLM 主流程** `run_evaluation.py`）；`model_family` 由 `msmodelslim-model-analysis` 回传的分析结论给出。
>
> 与 LLM/VLM 主流程的关系：主流程（SKILL.md）走 msmodelslim 服务化评测（Evaluation YAML + `run_evaluation.py`）；DiT 路径无 Evaluation YAML，agent 读 `<inference_repo>/README.md` 自拼 argv，执行本文 §3 bash 模板。两者的输入契约、输出格式完全独立，仅共用本 skill 入口。

## 1. 概述

DiT 调优回路的核心 step 4 工具，适配**任何已自带 `vbench.py` 的 DiT 推理仓**（Wan2.2 / HunyuanVideo / …）。不维护 flag 表、不硬编码任务名 —— 一切以**推理仓自带 README 为准**。

- **输入**：推理仓路径 + 输出目录 + vbench.py argv（agent 自拼）
- **机制**：agent 直接执行 §3 bash 模板；模板内嵌 `torchrun --nproc_per_node=N vbench.py ...`（多卡时按 README 给的姿势启）
- **输出**：`{workdir}/infer_outputs/round_{N}/<subdir>/<idx:04d>.mp4` + `run_manifest.json` + `vbench_runner.log`
- **不评分**：评分委托给 `quant-tuning-score-dit`（AISBench-VBench）

无 Python 包装层。本路径的全部逻辑就是 §3 模板 —— agent 按 README 拼 argv → 跑模板。

> 默认假设：主流 DiT 推理仓的 README 已经把 vbench.py 批量推理的姿势（torchrun 启动方式 / 环境变量 / 输出目录结构）写得很完善。agent 只需要照抄，不重复实现。

## 2. 适用与不适用

- **适用**：已经 `quant-tuning-quantize-dit` 产出量化权重，需要在 DiT 推理仓跑批量 VBench 推理
- **同样适用**：跑 **FP baseline** 推理 —— 同一 bash 模板。关键约定：
  - **`--ckpt_dir` 始终指向 FP 权重**（vbench.py 内部也读 FP base model；T5/VAE 等子模块也按 FP 加载）
  - 量化用**第二个 flag**（Wan2.2 是 `--quant_dit_path`，其它 DiT 仓名不同 —— **agent 必须读 `<inference_repo>/README.md` 查**）
  - FP baseline：**只传 `--ckpt_dir`，不传量化 flag**；输出到 `{workdir}/baseline_outputs/`
  - 量化推理：**两个都传**（`--ckpt_dir` 指向 FP + 量化 flag 指向量化产物）；输出到 `{workdir}/infer_outputs/round_{N}/`
  - FP 推理通常比量化慢 1.5-3×，orchestrator 启用 baseline 前必须先向用户回显预估时长
- **不适用**：
  - LLM/VLM 推理评测（走本 skill 主流程 `run_evaluation.py` 服务化路径）
  - 没有 `vbench.py` 的 DiT 仓（本路径强依赖该入口脚本）
  - 评分（由 `quant-tuning-score-dit` 接手）
  - 仅 smoke test（用 `quant-tuning-infer-dit`）

## 3. 执行模板

agent 必须先**读完** `<inference_repo>/README.md` 的 VBench 章节（不同仓库命名不同：Wan2.2 是 §7.4，HunyuanVideo 可能是另一节），确认 vbench.py 全部 flag、推荐的 `nproc_per_node`、env var 集合，然后按下表填变量并执行：

| 变量 | 来源 | 默认 |
|---|---|---|
| `INFER_REPO` | DiT 推理仓绝对路径 | 必填 |
| `FP_WEIGHTS` | FP base model 目录（vbench.py `--ckpt_dir` 接收） | 必填 |
| `QUANT_WEIGHTS` | 量化产物目录（Wan2.2 用 `--quant_dit_path`，其它仓名按 README） | 量化推理必填，FP baseline 留空 |
| `OUT_DIR` | 量化 → `{workdir}/infer_outputs/round_{N}/`；baseline → `{workdir}/baseline_outputs/` | 必填 |
| `ROUND` | orchestrator 轮次 | 必填 |
| `NPROC` | 可见 GPU 数（≤），与 `cfg_size × ulysses_size` 相等 | 按 README 推荐值 |
| `VBENCH_ARGS` | bash 数组，含 `--ckpt_dir $FP_WEIGHTS`；量化时再加量化 flag + `$QUANT_WEIGHTS` | 必填 |

> **快速验证 vs 正式评测**：跑通流程用 `--num_samples 1 --temporal_flickering_samples 1`（单条 video / 单条 flickering，几分钟出结果）。正式评分按 README 推荐值（如 Wan2.2 §7.4 正式推荐 `5 / 25`，单轮 92 条 video 跑数小时）。agent 自查：用户没明示时**默认 1/1**，避免误跑完整集浪费时间。

> **🚫 禁止默认开启 `--dit_fsdp` / `--t5_fsdp`**（Wan2.2 vbench.py §3 启的）：FSDP 在 vbench 批量推理下显存收益不抵吞吐退化，且与量化 + TP 组合有静默失效风险（见推理仓源码 `Wan2.2/vbench.py:478-480` TP>1 自动关 dit_fsdp；`vbench.py:535-536` quant+dit_fsdp 触发 `patch_cast_buffers_for_float8`）。**用户没显式说"开 FSDP"就一律不开**；真要开必须先和用户确认，并加进 `algo_decision`-like 字段写明 rationale。

#### ALGO 决策（必读，先于模板执行）

`ALGO` 选择 FA 计算路径，**错配不会报错，只静默污染 VBench 分数**——见推理仓源码 `Wan2.2/wan/modules/model.py:308-315`：`ALGO=3` 找不到 `fa_quant` 时自动 fall back 到 `fused_attn_score`，推理能跑完、出视频、AISBench 给分，但分反映的是另一条 FA 路径，与 baseline / 其它轮次**不可比**。

Wan2.2 README §3.1 矩阵（唯一内置规则，其它 DiT 仓不覆盖）：

| 设备 | 推理方式 | `ALGO` |
|---|---|---|
| Ascend 950 | FP / W8A8 / W4A4 量化 | `0` |
| Ascend 950 | W8A8c8 / W4A4c8 + attn FP8 | `0`（950 上未文档化，保守回退） |
| A2 / A3 | FP（baseline） | `1` |
| A2 / A3 | W8A8 / W4A4 MXFP8（仅 DiT 量化） | `0` |
| A2 / A3 | W8A8c8 / W4A4c8（DiT + attention FP8） | `3` |

模板 Step 0 用三段信息自动决策：(1) `npu-smi info -m` 设备家族 (2) `$INFER_REPO/README.md` 头部推理仓家族 (3) `QUANT_WEIGHTS` 路径 + 描述 JSON 中是否含 c8 配方专属 key (`qrot` / `krot` / `hadamard` / `fa_quant`)。决策结果写到 manifest 的 `algo_decision` 字段（含 family/device/quant/value/rationale/comparability_key）。

非 Wan2.2 推理仓（HunyuanVideo / FLUX / …）一律回退 `ALGO=0` 并写 warning；agent 须自行读该仓 README 的 ALGO 章节确认，**不要凭记忆写别的值**。

```bash
# === Step 0: ALGO 决策（auto-detect；Wan2.2 严格按 README §3.1 矩阵） ===
# 检测三段：(1) npu-smi 设备家族 (2) $INFER_REPO/README.md 头部推理仓家族
#          (3) QUANT_WEIGHTS 路径 / quant_model_description_*.json attn 行 → 量化配方
# 决策写盘到 /tmp/_algo_decision.json + 通过 stdout 经 eval 传回 bash 环境变量
export QUANT_WEIGHTS="${QUANT_WEIGHTS:-}"
eval "$(python3 - <<'PYEOF'
import json, os, re, shlex, pathlib, subprocess

INFER_REPO = os.environ["INFER_REPO"]
QUANT_W    = os.environ.get("QUANT_WEIGHTS", "").strip()

def detect_device():
    try:
        out = subprocess.check_output("npu-smi info -m 2>/dev/null", shell=True, text=True)
    except Exception:
        return "unknown", ""
    m = re.search(r"Ascend\s+(\S+)", out)
    if not m: return "unknown", ""
    chip = m.group(1)
    if chip.startswith("950"):  return "ascend_950", chip
    if chip.startswith("910B"): return "ascend_a2", chip
    if chip.startswith("910C"): return "ascend_a3", chip
    return "unknown", chip

def detect_family():
    rd = pathlib.Path(INFER_REPO, "README.md")
    if not rd.is_file(): return "unknown"
    head = rd.read_text(errors="ignore")[:2000]
    if re.search(r"Wan\s*2\.2|Wan2\.2", head): return "wan2.2"
    return "unknown"  # 非 Wan2.2 → 默认 ALGO=0 + warn，agent 自查

def detect_quant(qpath):
    if not qpath: return "fp"
    # 信号 1：路径串含 c8 / attn_fp8 / attn-fp8 → with_attn_fp8
    name = qpath.lower()
    if "c8" in name or "attn_fp8" in name or "attn-fp8" in name: return "with_attn_fp8"
    # 信号 2：路径串含 w8a8 / w4a4 / w8a16 / w4a16 → base
    if re.search(r"w8a8|w4a4|w8a16|w4a16", name): return "base"
    # 信号 3：扫描述 JSON，看是否含 c8 配方专属 key（qrot / krot / hadamard / fa_quant）
    #         注意：attn.q/k/v/o 标注 W8A8_MXFP8 不算 c8，那只是 MXFP8 对 qkv proj 的量化
    for p in pathlib.Path(qpath).rglob("quant_model_description*.json"):
        try: d = json.loads(p.read_text())
        except Exception: continue
        for k in d.keys():
            kl = k.lower()
            if any(t in kl for t in ("qrot", "krot", "hadamard", "fa_quant")):
                return "with_attn_fp8"
        return "base"
    return "unknown"

def decide(family, device, quant):
    if family != "wan2.2":
        return "0", f"family={family} 非 Wan2.2 → 默认 ALGO=0（agent 须读 {INFER_REPO}/README.md 自行确认）"
    if device == "ascend_950":
        if quant == "with_attn_fp8":
            return "0", "Ascend 950 + c8 未文档化 → 保守回退 ALGO=0"
        return "0", f"Ascend 950 + {quant} → ALGO=0"
    if device in ("ascend_a2", "ascend_a3"):
        if quant == "fp":             return "1", "A2/A3 FP baseline → ALGO=1"
        if quant == "base":           return "0", "A2/A3 W8A8/W4A4 MXFP8 → ALGO=0"
        if quant == "with_attn_fp8":  return "3", "A2/A3 W8A8c8/W4A4c8 + attn FP8 → ALGO=3"
        return "0", "A2/A3 + 配方未识别 → 默认 ALGO=0"
    return "0", "设备未识别 → 默认 ALGO=0"

device, chip = detect_device()
family      = detect_family()
quant       = detect_quant(QUANT_W)
algo, why   = decide(family, device, quant)
unknown     = family != "wan2.2" or device == "unknown" or quant == "unknown"
comp_key    = f"{family}|{device}|{quant}|ALGO={algo}"

result = {
    "family": family, "device": device, "device_chip": chip,
    "quant": quant, "quant_weights_path": QUANT_W,
    "value": algo, "rationale": why, "unknown": unknown,
    "comparability_key": comp_key,
}
pathlib.Path("/tmp/_algo_decision.json").write_text(json.dumps(result, ensure_ascii=False))

q = shlex.quote
print(f"export ALGO_RESOLVED={q(algo)}")
print(f"export ALGO_KEY={q(comp_key)}")
print(f"export ALGO_UNKNOWN={1 if unknown else 0}")
import sys
print(f"# algo_decision: family={family} device={device} chip={chip} quant={quant} → ALGO={algo}", file=sys.stderr)
PYEOF
)"

# === Step 1: 校验 + 写 run_manifest.json ===
# 把 VBENCH_ARGS 通过文件传递，避开 shell 引号嵌套
printf '%s\n' "${VBENCH_ARGS[@]}" > /tmp/_vbench_args.$$
export VBENCH_ARGS_FILE=/tmp/_vbench_args.$$
export OUT_DIR ROUND INFER_REPO NPROC

python3 - <<'PYEOF'
import json, os, sys, pathlib, subprocess
errs = []
def flag(args, f):
    for i, a in enumerate(args):
        if a == f and i + 1 < len(args): return args[i + 1]
        if a.startswith(f + "="): return a[len(f) + 1:]
    return None
def intv(args, f):
    v = flag(args, f)
    return int(v) if v and v.lstrip("-").isdigit() else None

args = pathlib.Path(os.environ["VBENCH_ARGS_FILE"]).read_text().splitlines()
nproc = int(os.environ["NPROC"])

algo_decision = json.loads(pathlib.Path("/tmp/_algo_decision.json").read_text())
algo = algo_decision["value"]

ckpt = flag(args, "--ckpt_dir")
if ckpt and not pathlib.Path(ckpt).expanduser().is_dir():
    errs.append(f"--ckpt_dir not a dir: {ckpt}")
root = flag(args, "--vbench_mini_root")
if flag(args, "--vbench_mini") and root and not pathlib.Path(root).expanduser().is_dir():
    errs.append(f"--vbench_mini_root not a dir: {root}")
save = flag(args, "--save_path")
if save and not pathlib.Path(save).expanduser().resolve().parent.is_dir():
    errs.append(f"--save_path parent not a dir: {save}")
for f in ("--frame_num", "--sample_steps", "--num_samples", "--temporal_flickering_samples"):
    v = intv(args, f)
    if v is not None and v <= 0:
        errs.append(f"{f} must be positive: {v}")
cfg, uly = intv(args, "--cfg_size") or 1, intv(args, "--ulysses_size") or 1
if cfg * uly != nproc:
    errs.append(f"cfg_size({cfg}) * ulysses_size({uly}) = {cfg * uly} != nproc_per_node({nproc})")

warns = []
try:
    gpu = int(subprocess.check_output("nvidia-smi -L 2>/dev/null | wc -l", shell=True, text=True).strip() or 0)
except Exception:
    gpu = 0
if gpu and nproc > gpu:
    warns.append(f"nproc_per_node({nproc}) > visible GPUs({gpu})")

# 🚫 FSDP 默认禁止（Wan2.2 vbench 批量推理）：agent 误传时 stderr warn + 写进 manifest，不阻塞
#    理由：批量推理下 FSDP 吞吐退化 > 显存收益；与 TP>1 静默互斥（vbench.py:478-480）；
#          与 --quant_dit_path 联动触发 patch_cast_buffers_for_float8（vbench.py:535-536）。
#    例外：用户显式说"开 FSDP"才允许；agent 自查（§7 清单）。
fsdp_enabled = []
if "--dit_fsdp" in args: fsdp_enabled.append("--dit_fsdp")
if "--t5_fsdp"  in args: fsdp_enabled.append("--t5_fsdp")
if fsdp_enabled:
    msg = (f"⚠️  检测到 FSDP flag {fsdp_enabled} — 默认禁止。"
           f"Wan2.2 vbench 批量推理下 FSDP 吞吐退化 > 显存收益；如非用户显式要求，"
           f"请从 VBENCH_ARGS 中移除。已写进 manifest.warnings，不阻塞本次运行。")
    warns.append(msg)
    print(msg, file=sys.stderr)
    manifest_fsdp_opt_in = {"flags": fsdp_enabled, "explicit_user_request": None}
else:
    manifest_fsdp_opt_in = {"flags": [], "explicit_user_request": False}

if errs:
    print(json.dumps({"ok": False, "error_code": "VBENCH_ARGS_INVALID", "errors": errs}, indent=2))
    sys.exit(2)

out = pathlib.Path(os.environ["OUT_DIR"])
out.mkdir(parents=True, exist_ok=True)
if algo_decision["unknown"]:
    warns.append(f"ALGO 决策含未识别项（family={algo_decision['family']}, device={algo_decision['device']}, quant={algo_decision['quant']}），已默认 ALGO=0 — agent 须读 $INFER_REPO/README.md 自行确认")
manifest = {
    "version": "1.0",
    "round": int(os.environ.get("ROUND", "0") or 0),
    "inference_repo": os.environ["INFER_REPO"],
    "nproc_per_node": nproc,
    "vbench_args": args,
    "command": f"torchrun --nproc_per_node={nproc} vbench.py {' '.join(args)}",
    "auto_env_overrides": {
        "ALGO": algo,
        "PYTORCH_NPU_ALLOC_CONF": "expandable_segments:True",
        "TASK_QUEUE_ENABLE": "2",
        "CPU_AFFINITY_CONF": "1",
        "TOKENIZERS_PARALLELISM": "false",
        "FAST_LAYERNORM": "1",
    },
    "algo_decision": algo_decision,
    "fsdp_opt_in": manifest_fsdp_opt_in,
    "warnings": warns,
}
(out / "run_manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
print(json.dumps({"ok": True, "manifest_path": str(out / "run_manifest.json"), "warnings": warns}))
PYEOF

# === Step 2: torchrun 启 vbench.py（按 README 给的姿势；Wan2.2 默认 master_port=23459） ===
cd "$INFER_REPO"
export ALGO="$ALGO_RESOLVED" PYTORCH_NPU_ALLOC_CONF='expandable_segments:True' \
       TASK_QUEUE_ENABLE=2 CPU_AFFINITY_CONF=1 \
       TOKENIZERS_PARALLELISM=false FAST_LAYERNORM=1
nohup torchrun --nproc_per_node="$NPROC" --master_port=23459 \
    vbench.py "${VBENCH_ARGS[@]}" \
    > "$OUT_DIR/vbench_runner.log" 2>&1 &
PID=$!

# === Step 3: heartbeat（orchestrator grep [heartbeat]/[tail] 判活） ===
START=$(date +%s)
while kill -0 $PID 2>/dev/null; do
    sleep 60
    ELAPSED=$(($(date +%s) - START))
    echo "[heartbeat] elapsed=${ELAPSED}s"
    tail -5 "$OUT_DIR/vbench_runner.log" 2>/dev/null | sed 's/^/[tail] /'
done
wait $PID; RC=$?

# === Step 4: msagent-io v1 envelope ===
STATUS=$([ $RC -eq 0 ] && echo ok || echo failed)
cat <<EOF
{"protocol":"msagent.subagent_io","subagent_type":"quant-tuning-evaluate",
 "status":"$STATUS","output":{"ok":$([[ $RC -eq 0 ]] && echo true || echo false),
 "exit_code":$RC,"log_path":"$OUT_DIR/vbench_runner.log",
 "manifest_path":"$OUT_DIR/run_manifest.json"}}
EOF
exit $RC
```

模板校验失败的 exit code 是 `2`（stderr 一行 JSON `{ok:false,error_code:VBENCH_ARGS_INVALID,errors:[...]}`），orchestrator 据此分支。

## 4. 无超时 + 心跳 tail

**不设硬超时**。DiT 批量推理单条 video 4 卡常 10-20 分钟，整轮 92 条 video 可达数小时。旧 `subprocess.run(timeout=7200)` 在 2 小时误杀子进程 → orchestrator 误判 OOM。

模板行为：
- `nohup ... &` 异步启动，日志落 `$OUT_DIR/vbench_runner.log`
- 每 60s 往 stdout 一行 `[heartbeat] elapsed=Ns` + 最近 5 行日志（`[tail] ...`）
- orchestrator grep 心跳行 + 比较日志增长判断子进程真在推进
- Ctrl-C → `kill -TERM $PID`，bash 默认 wait；torchrun worker 会收尾

## 5. `run_manifest.json` sidecar

模板第 1 步写盘，下游 `quant-tuning-score-dit` 读它填 envelope 的 `inference_params` 字段。

```json
{
  "version": "1.0",
  "round": 2,
  "inference_repo": "/path/to/Wan2.2",
  "nproc_per_node": 4,
  "vbench_args": ["--task", "t2v-A14B", "--ckpt_dir", "/path/to/fp_wan22_weights", "--quant_dit_path", "/path/to/quant_w8a8", "..."],
  "command": "torchrun --nproc_per_node=4 vbench.py --task t2v-A14B ...",
  "auto_env_overrides": {
    "ALGO": "0", "PYTORCH_NPU_ALLOC_CONF": "expandable_segments:True",
    "TASK_QUEUE_ENABLE": "2", "CPU_AFFINITY_CONF": "1",
    "TOKENIZERS_PARALLELISM": "false", "FAST_LAYERNORM": "1"
  },
  "algo_decision": {
    "family": "wan2.2", "device": "ascend_a2", "device_chip": "910B2",
    "quant": "base", "quant_weights_path": "/path/to/quant_w8a8",
    "value": "0",
    "rationale": "A2/A3 W8A8/W4A4 MXFP8 → ALGO=0",
    "unknown": false,
    "comparability_key": "wan2.2|ascend_a2|base|ALGO=0"
  },
  "fsdp_opt_in": {
    "flags": [],
    "explicit_user_request": false
  },
  "warnings": []
}
```

`ALGO` 是 Step 0 auto-detect 后的值（不再写死 `1`）；`algo_decision` 是结构化决策记录，下游 aggregate 用 `comparability_key` 做跨轮次 ALGO 漂移检测。

manifest 在 torchrun 启动**之前**写盘（Step 1）→ 即使后续 crash 也有尝试的参数记录。覆盖式 —— 同 `OUT_DIR` 多次运行只保留最后一次 manifest。

**缺失降级**：下游评分读不到 manifest 时 `inference_params` 字段省略（stderr warning），不阻塞评分。

## 6. 输出 envelope（msagent-io v1）

模板 Step 4 输出（成功 / 失败同一格式，`status` 区分；`subagent_type` 统一为本 skill `quant-tuning-evaluate`，`model_family` 由分析结论携带）：

```json
{
  "protocol": "msagent.subagent_io",
  "subagent_type": "quant-tuning-evaluate",
  "status": "ok",
  "output": {
    "ok": true,
    "exit_code": 0,
    "log_path": "{workdir}/infer_outputs/round_2/vbench_runner.log",
    "manifest_path": "{workdir}/infer_outputs/round_2/run_manifest.json"
  }
}
```

`status=failed` 时 `output.ok=false`、`output.exit_code=非零`；模板 Step 1 校验失败则 `status=failed`、`exit_code=2`、stderr 多一行 `VBENCH_ARGS_INVALID` JSON。orchestrator 读 `output.exit_code` + `vbench_runner.log` 尾部诊断。

## 7. 检查清单（agent 跑前自查）

- [ ] `<inference_repo>/README.md` 的 VBench 章节读完，**flag 拼对（不要凭记忆）**——尤其确认量化 flag 名（Wan2.2 是 `--quant_dit_path`，其它仓可能不同）
- [ ] `INFER_REPO/vbench.py` 存在
- [ ] `OUT_DIR` 不存在或可写；父目录存在
- [ ] `--ckpt_dir` **始终**指向 FP base model 目录（量化推理和 FP baseline 都用 FP 路径）
- [ ] 量化推理时：除 `--ckpt_dir` 外，还要传**量化 flag**（Wan2.2 `--quant_dit_path`）+ 量化产物路径
- [ ] FP baseline 时：**不传**任何量化 flag
- [ ] `--vbench_mini_root` 指向 `VBench-1.0-mini/`（含 `VBench_kmeans_info.json`）
- [ ] `cfg_size × ulysses_size == NPROC`（**最常见踩坑**，模板会自动校验）
- [ ] `NPROC` ≤ `nvidia-smi -L` 看到的 GPU 数
- [ ] `disk_space >= N_rounds × ~5GB`（每轮 92 条 video 粗估，按 README 数据集大小调整）
- [ ] **跑 FP baseline 时**：用户已显式确认、orchestrator 已回显预估时长（FP 比量化慢 1.5-3×）
- [ ] **ALGO 决策自检**：Step 0 跑完，stderr 输出 `algo_decision: family=… device=… chip=… quant=… → ALGO=…` —— 逐项核对是否符合预期（特别是 Wan2.2 量化推理应得 `ALGO=0` 或 `ALGO=3`，**不是 `1`**）

## 8. 相关文档

- 既有 DiT smoke：[quant-tuning-infer-dit](../../../quant-tuning-infer-dit/SKILL.md)
