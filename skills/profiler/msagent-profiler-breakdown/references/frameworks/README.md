# 框架扩展指南（如何新增 / 扩充拆解场景）

> 本目录放框架打点的**事实清单**（供人阅读与核验）；引擎只读 `resources/scenarios/<scenario>/<framework>.json`
> 的**声明式规则**执行拆解。新增框架 = 加一个场景资源文件，**不改引擎**。

## 一、引擎与规则的解耦

```
msagent-profiler-breakdown/
├── scripts/decompose.py            # 引擎：场景确认 + 阶段/step 拆解 + 报告（框架无关）
├── resources/scenarios/            # 场景规则（引擎唯一读取来源）
│   ├── inference/vllm.json         #   推理：vLLM 五 stage + forward 锚点（已核验）
│   ├── inference/sglang.json       #   推理：SGLang（占位，待核验）
│   ├── training/megatron.json      #   训练：Megatron（占位）
│   ├── training/mindspeed.json     #   训练：继承 megatron（占位）
│   ├── training/fsdp.json          #   训练：继承 megatron（占位）
│   ├── rl/verl.json                #   RL：verl 11 阶段（MSTX_EVENTS，已核验）
│   └── rl/slime.json               #   RL：slime（占位，待核验）
└── references/frameworks/          # 框架打点事实清单（人读，非规则）
    ├── README.md                   #   本文档
    ├── vllm.md                     #   vLLM 阶段五 stage + step 边界 + 图捕获约束（合并原两份）
    ├── vllm-instrumentation.md     #   vLLM / vLLM-Ascend 打点事实清单
    ├── vllm-profiler-data.md       #   PyTorch Profiler 采集数据与字段 → 拆解维度
    └── verl.md                     #   verl MSTX / record_function 打点清单
```

引擎启动时扫描 `resources/scenarios/<scenario>/*.json` 构建注册表（`framework → scenario → rules`），
`--framework` 未命中时按任务类型回退（推理 → vllm 兜底并告警；训练/RL → 空占位）。

## 二、场景资源 JSON 契约

```jsonc
{
  "framework": "vllm",                 // 框架名（文件内声明；缺省取文件名）
  "scenario": "inference",             // 任务类型：inference | train | rl（决定场景目录）
  "label": "vLLM 推理（decode 先行）",    // 人类可读说明
  "extends": null,                     // 继承另一框架的规则（如 mindspeed extends megatron）；null 表示无
  "stage_decompose": {                 // 阶段归因规则
    "backing": "PYTORCH_API",          //   阶段事件来源表：PYTORCH_API（JOIN name）| MSTX_EVENTS（JOIN message）
    "note": "…",                       //   规则说明 / 核验状态
    "stages": [                        //   阶段清单（按语义名聚合；一个 stage 可含多个 scope）
      {"name": "forward", "scopes": ["forward"]}
    ]
  },
  "step_decompose": {                  // 单次执行边界规则
    "backing": "PYTORCH_API",          //   锚点事件来源表
    "anchor": ["forward"],             //   边界锚点 scope（每次执行出现一次）；空数组 = 跳过 step 拆解
    "note": "…",
    "position_warmup": 2,              //   位置性热身步数（前 N 步判图捕获/编译）
    "warmup_factor": 3.0               //   阈值兜底：wall_time > factor × median 判为热身
  }
}
```

字段可选：`stage_decompose` / `step_decompose` 可整体缺省（视为空规则）；`extends` 时子文件
`stages` / `anchor` 与父规则取并集，其余字段子覆盖父。

## 三、新增框架三步

1. **核验打点**：用 `scripts/db_query.py` 查真实 profiling 数据，确认阶段 scope 名与 step 锚点
   （`python db_query.py string --db <db> --prefix vllm` 等）。
2. **写资源文件**：在对应场景目录放 `<framework>.json`（参考 vllm.json / verl.json）；
   未核验的字段留空数组并在 `note` 标注「待核验」。
3. **跑通校验**：`python decompose.py --db <db> --framework <fw> [--task-type ...]`，
   检查阶段统计与 step 边界是否符合预期。

### 边界锚点候选（按框架）

| 场景        | 锚点候选                                                       | 说明                              |
| --------- | ---------------------------------------------------------- | ------------------------------- |
| 推理 decode | `forward` scope / `STEP_TIME` 表 / lm\_head 首层 kernel（C 策略） | vLLM-Ascend 已核验为 `forward`      |
| 训练        | optimizer 更新 kernel（Adam 类）/ fwd-bwd 锚点                    | 待核验（megatron/mindspeed/fsdp 占位） |
| RL        | `actor_update` / `update_actor`（单次 actor 更新边界）             | 待核验；dataloader 子粒度问题待解          |

## 四、框架打点事实清单（人读）

- `vllm.md`：vLLM 推理五 stage 判别 + step 边界锚点 + capture\_size / 图捕获对层拆解的硬约束 + PP 分层映射。

- `vllm-instrumentation.md`：vLLM / vLLM-Ascend `record_function_or_nullcontext` / MSTX 打点
  事实清单 + 打点 → 拆解维度映射（含对既有 profile 的错误命名纠正）。

- `vllm-profiler-data.md`：PyTorch Profiler（torch.profiler / torch\_npu.profiler / MSTX）
  采集数据与字段 → 拆解维度映射（prefill/decode 判别、step 边界、层归属、通信归因等）。

- `verl.md`：verl MSTX（worker 侧 DistProfiler.annotate / trainer 侧 marked\_timer）与
  record\_function 打点全清单 + 两侧命名对齐映射。

> 事实清单变更需同步核对对应场景资源 JSON 的 scope / anchor，避免文档与规则脱节。

