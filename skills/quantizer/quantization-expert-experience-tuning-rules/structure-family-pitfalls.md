# L2 结构化专家调优意见

> **定位与阅读规则**
> - 本文件**仅对某类结构成立**（MoE / MLA / 混合 attention / 自定义 modeling / VLM / DiT / DSA-SWA-GatedDeltaNet / Dense FFN）。
> - 先按**触发信号**判断新模型属于哪几类（可以多属），再**叠加 L1 读本文件对应小节**。
> - 每条经验附专家原因与专家意见可信度；结构模型类内的「回退」只是手段之一，同样涵盖离群值抑制、量化方法选型、结构映射等手段。

---

## 触发信号 → 结构模型类速查

| 触发信号（从 `named_modules` / config 判断） | 归属模型类 | 本节 |
|---|---|---|
| 存在 `*.experts.*` / `*.mlp.experts.*` / routed+shared experts | MoE | §1 |
| 存在 `router` / `gate` / `*.mlp.gate` / `*.router.gate` | MoE（路由层） | §1 |
| 存在 `kv_b_proj` / `q_a_proj` / `kv_a_proj` / `wk` / `weights_proj` / `wq_b` | MLA 低秩投影 | §2 |
| 存在 `linear_attn` / `gated_delta_net` / `dsa` / `swa` 结构 | 混合 attention / 特殊结构 | §3 §5 |
| 自定义 `modeling_*.py`（非标准 transformers 结构命名） | 自定义 modeling | §4 |
| 含 `vision_tower` / `merger` / `multi_modal_projector` 等跨模态结构 | VLM | §6 |
| DiT / 扩散生成主干 + `mod`/调制模块 | DiT/扩散 | §7 |
| 纯 dense FFN（`mlp.gate_proj/up_proj/down_proj`，无 experts） | Dense FFN | §8 |

---

## 1. MoE 模型类

### 1.1 核心区分

必须区分四类：**路由层（gate/router）/ routed experts / shared_experts / 普通 attention 与 FFN**。不要把「属于 expert」当作整体回退理由。

### 1.2 通用原则（横跨三格式）

| 模块 | 默认处理 | 说明 |
|---|---|---|
| `gate` / `router` | 排除量化 / 保持高精度 | 路由决策敏感，是**结构性排除**，非普通线性层逐层回退。量化误差可能导致 token 路由到错误 expert |
| `shared_experts` | 通常保持高精度 | 与 routed experts 计算路径不同，每层共享被所有 experts 复用，误差会被全局放大 |
| routed experts 普通 `up_proj/down_proj` | 默认量化 | 只有敏感层/精度结果支持时才回退。experts 数量多，是低比特的主要收益来源 |
| MLA 低秩投影（`kv_b_proj` 等） | 条件性排除 | 仅当结构存在（见 §2）。低秩投影承载逐头信息压缩，量化误差会沿 attention 路径传播 |

- 以上原则基于 MoE 结构特性推断：gate/router 属离散路由决策路径，shared_experts 属全局复用路径，均对量化误差高度敏感。专家意见可信度：高。

### 1.3 按格式的低比特落点

| 格式 | 低比特落点 | attention / 一般 FFN |
|---|---|---|
| W8A8 | 无（experts 也走 W8A8） | W8A8 |
| W4A8 | `*mlp.experts*`（int4 权重 + ssz） | 保持 W8A8 |
| W4A4 | `*mlp.experts.*`（int4×int4） | 提级 W8A8 |

- 低比特落点按「experts 容量大、适合低比特压缩」的原则分配，attention 与一般 FFN 保持高精度以保障整体表征质量。专家意见可信度：高。

### 1.4 常见敏感层与提级手法

- **敏感层专家提级**：把「某几层 experts」从 W4A8 单列提级回 W8A8（如 `model.layers.41~47.mlp.experts*`），其余 experts 落 W4A8 —— 即「专家整体 W4 + 指定高敏感层专家 W8」是通用手法。原因：这些层在模型中扮演关键信息整合角色，量化误差经后续层传播会显著累积。
- **首几层保护**：`flex_awq_ssz` 中排除 `model.layers.0/1/2.*`，避免低比特权重在模型早期对后续所有层传播误差。
- **`o_proj`（self_attn 输出投影）**：精度不达标时作为结构化回退候选，`exclude` 增加 `*.o_proj`（单层投影保持浮点），**非整层回退**。原因：o_proj 汇聚 attention 全部头的输出，是表征质量的聚合点。
- **`*mlp.down_proj*` / `*shared_experts.down_proj*`**：输出投影回退候选（与 L1 通用结论同源）。原因：输出投影聚合上游激活，量化误差在此放大。

- 敏感层选择须结合目标模型的敏感层分析实测确认。专家意见可信度：中（具体层号随模型不同）。

---

## 2. MLA 低秩投影模型类

### 2.1 触发信号

出现 `kv_b_proj` / `q_a_proj` / `kv_a_proj` / `wk` / `weights_proj` / `wq_b` / `wo_a` / `wo_b` 等低秩/分解投影。

### 2.2 规则

| 模块 | 处理 | 说明 |
|---|---|---|
| `*kv_b_proj`、`*wk`、`*weights_proj` | 高频条件性排除 | MLA 低秩投影，承载逐头 Key/Value 压缩信息，量化误差会沿 attention 计算路径传播 |
| `*q_a_proj` / `*kv_a_proj` | 是否量化、量化到哪档**必须按结构逐项确认** | 不可只记 `kv_b_proj` 一句话，需结合具体模型结构判断 |
| `*wo_a`/`*wo_b`/`*compressor.*`/`*indexer.weights_proj` | 条件性排除 | DeepSeek-V4 类索引/压缩投影，属模型特有结构，量化敏感 |

- MLA 低秩投影是 attention 的压缩瓶颈，信息密度高，量化后损失可逆性差。专家意见可信度：高（排除方向）、中（具体层号/档位）。

---

## 3. 混合 attention 模型类（MLA + GatedDeltaNet + 线性 attention）

### 3.1 触发信号

同时存在 `self_attn`（MLA）与 `linear_attn` / `gated_delta_net` 等混合结构；常见命名 `linear_attn.in_proj_qkvz` 等。

### 3.2 规则

- 混合 attention 中，线性 attention 的投影（如 `linear_attn.in_proj_qkvz`）可与 MLA 分开量化，单列 include 以适配各自分布特征。
- 混合结构中 MLA 低秩投影仍按 §2 排除。
- 混合 attention 中，不同注意力路径（MLA / 线性注意力）计算特性差异大，分开量化各取合适格式；MLA 低秩投影仍按 §2 排除。专家意见可信度：中。

---

## 4. 自定义 modeling 模型类

### 4.1 触发信号

非标准 transformers 结构命名（`*.ffn.shared_experts.*`、`*.block_sparse_moe.*`、`*.mlp.expert_bias` 等），或模型目录内自定义 `modeling_*.py`。

### 4.2 规则

- **结构命名可能偏离常规**：如 DeepSeek-V4 的 FFN 用 `ffn` 而非 `mlp`、shared experts 为 `ffn.shared_experts`；MiniMax 用 `block_sparse_moe.experts`；Hy3 有 `mlp.expert_bias`、`router.gate`。原因：不同模型实现使用了不同的模块命名约定，照搬 `mlp` 前缀会匹配不到层。
- 处理前**必须先取得真实 `named_modules`**，不要把 `mlp`/`self_attn` 等常规前缀硬套。专家意见可信度：高。

---

## 5. DSA / SWA / GatedDeltaNet 特殊结构

### 5.1 规则

- DSA / SWA / GatedDeltaNet 三类结构承担交替扫描/线性注意力等特殊功能，计算路径与标准 attention 差异大，处理流程以保持高精度为原则，默认进入量化范围外，若要量化需**另确认处理器/推理引擎支持**。
- 这是结构保持高精度的**结构映射结论**，不是量化后测评结论。专家意见可信度：高（映射存在）、中（量化可行性未验证）。

---

## 6. VLM 模型类

### 6.1 规则

- **初版仅量化 LLM 部分**：视觉编码器（`vision_tower`）、跨模态投影/融合层（`merger` / `multi_modal_projector` / `patch_merge_mlp`）先不量化，常见排除。原因：跨模态投影层连接不同模态空间，量化误差可能破坏模态对齐。
- 注意 VLM 的 apiversion 可能为 `multimodal_vlm_modelslim_v1`，与纯文本 `modelslim_v1` 区分。专家意见可信度：中。

---

## 7. DiT / 扩散生成模型类

### 7.1 触发信号

**结构特征**：`named_modules` 中存在**重复堆叠的 transformer block 容器**，每个 block 子模块包含两个核心分支：

- **attention 分支**（self-attn、cross-attn、single-stream attn，或融合如 FLUX 的 `single_*`）
- **FFN 分支**（up/gate/down 或等价 MLP）

可选的 **mod / modulation 分支**（时序/条件信号注入），常见于扩散模型。

**容器命名约定**（仅作 `block_container` 自动探测的候选，不要求完全一致）：

| 常见容器名 | 出现模型 |
|---|---|
| `blocks` | Wan2.2、Wan2.1、SD3、Sana、HunyuanDiT、CogViewX |
| `transformer_blocks` | HunyuanVideo |
| `single_transformer_blocks` | FLUX.1-dev（融合流） |

> §7 的所有经验基于"transformers 风格的重复 block 堆叠"这一**结构特征**，不依赖具体命名。容器名差异由 [`scripts/apply_rollback.py`](scripts/apply_rollback.py) 自动探测处理（见 §7.3 容器名列）。

### 7.2 通用规则（**整层回退是主路径**）

| 优先级 | 模块 | 处理 | 说明 |
|---|---|---|---|
| **1（首选 / 默认）** | **早期若干 DiT block 整块回退** | `*blocks.{i}.*` 整块排除 | **DiT 调优的主路径**。`first_n_blocks=N` → `*blocks.0.*` … `*blocks.{N-1}.*`，每条 glob 用 `.{i}.*` 命中该 block 下**全部**子模块（attn.* / ffn.* / norm / modulation / projection）——「把 block {i} 整体踢出量化范围」，**不是**只回退某个子结构 |
| 2（可选叠加） | `*ffn.down*` / `mlp.down_proj` / `ffn.w2` | 跨所有 block 排除 | FFN 输出投影聚合 up/gate 激活信号，量化误差易在此累积放大；与整层回退叠加使用 |
| 2（可选叠加） | `*attn.out_proj*` / `attn.o_proj` / `attn.wo` | 跨所有 block 排除 | attention 输出投影聚合多头输出，对表征质量影响大；与整层回退叠加使用 |
| 3（条件性） | `mod` / `modulation` / 文本·图像调制首层 | 条件性排除 | 调制模块控制生成时序/条件信号，误差敏感；Wan2.2 / HunyuanDiT / FLUX 按结构确认 |
| 4（仅低比特） | SVDQuant 类方案 | 离群值迁移 + SVD 低秩残差 + 残差量化 | 解决扩散模型激活离群值强的问题；W4A8 / W4A4 路径 |

- **先做整层回退**（优先级 1），评估未达标再叠加结构性回退（优先级 2）；不要跳过整层回退直接做结构性回退。
- **"整块"语义**：点号分隔 `.{i}.*` 保证只命中 block {i} 内的层，不污染 `blocks.{i+1}` 或顶层非 block 模块。
- 不建议子结构回退（如 `*blocks.0.attn.out_proj*`）——粒度过细，违反"整块"语义；如需精细化应走 L1 §5 敏感层分析路径。
- 不建议整网络回退（`first_n_blocks` 超过总块数）——等价于 FP 推理。
- 上述规则在 Wan2.2 / FLUX / SD3 / HunyuanDiT / Sana / CogViewX 等 DiT 模型族上经验有效；具体 N 值见 §7.3。
- 专家意见可信度：**高**（整层回退的早期敏感假设）/ **中**（具体 N 值与 pattern 是否包含 `qkv` / `q/k/v` 因模型而异）。

### 7.3 DiT 模型族整层回退默认值

> Agent 调优 DiT 精度时，在本表取默认 `first_n_blocks` → 交给 [`scripts/apply_rollback.py`](scripts/apply_rollback.py) 执行（CLI 仅需 `--first-n-blocks N`，结构性 pattern 由经验库隐式注入）。用户可在 `user_input` 阶段覆盖。

| 模型族 | `first_n_blocks` | 容器名 | 结构化 pattern（可选叠加） |
|---|---|---|---|
| **Wan2.2-T2V-A14B** | `5` | `blocks` | `*ffn.down*`, `*attn.out_proj*`（双 expert、双 block 列表，high/low noise 各一套） |
| **Wan2.2-I2V-A14B** | `5` | `blocks` | 同 T2V-A14B |
| **Wan2.2-TI2V-5B** | `3` | `blocks` | 同 T2V-A14B（单 expert，参数小，N 略小） |
| **Wan2.1-T2V-14B** | `5` | `blocks` | `*ffn.down*` |
| **FLUX.1-dev** | `5` | `single_transformer_blocks` | `*ffn.down*`, `*attn.qkv*`（无 cross-attn） |
| **HunyuanVideo** | `8` | `transformer_blocks` | `*ffn.down*`, `*attn.qkv*`（模型大、N 略大） |
| **SD3 / Sana / HunyuanDiT / CogViewX** | `5` | `blocks` | `*ffn.down*`, `*attn.out_proj*` |

#### 7.3.1 调优步进

```
轮 1：first_n_blocks = N（模型族默认值） + 可选叠加 ffn.down + attn.out_proj
      ↓ 评估未达预期
轮 2：first_n_blocks += 5 → N+5
      ↓ 评估仍未达预期
轮 3：继续 first_n_blocks += 5 → N+10
      ↓ 评估仍未达预期
轮 4：考虑切换低比特方案（SVDQuant）/ 换 FP16 推理
```

- 每轮只在 `first_n_blocks` 一个数上做加法（增量 5），不改 pattern —— 这是 DiT 调优最简洁的步进路径。
- 不建议调小 `first_n_blocks`（已回退的 block 重新量化通常会让误差反弹）。
- 专家意见可信度：W8A8 **高**、W4A4 **中**（DiT 低比特实践较少）。

---

## 8. Dense FFN 模型类（非 MoE）

### 8.1 通用原则

- 普通 attention（`q/k/v/o_proj`）与 FFN 主体**默认继续量化**，只有敏感层分析/精度结果支持时才回退。
- **不因模块名直接判定回退**（`gate_proj`/`down_proj`/`o_proj`），先确认父模块与层范围。原因：同一模块名在不同模型中的敏感度差异大。
- `o_proj` 不能泛化为「所有 attention 都应回退」。原因：o_proj 敏感度受模型规模、训练方式影响，不可一刀切。

### 8.2 按格式

| 格式 | 关键经验 |
|---|---|
| W8A8 | `mlp.down_proj` 优先回退候选（层范围按模型确认）；无其他默认回退 |
| W4A8 | dense 无 experts，低比特可能全 FFN 或按敏感度拆分，**不照搬 MoE experts 低比特模式**，无明确证据时不整体回退 FFN |
| W4A4 | 权重+激活均低比特，回退更保守；更常见「首几块提级 W8A8」而非整体逐层回退 |

### 8.3 W4A4 结构化拆分（观测）

| 结构 | 处理 |
|---|---|
| 前若干主干块 | 提级 W8A8（首几块高精度档位，避免误差早期传播） |
| 自注意力 | 提级 W8A8（高精度） |
| 文本/图像调制首层 | 排除 |
| 低秩投影 | 排除 |

- 结构化拆分原则：越早期、越聚合的结构越敏感；低秩投影信息密度高，优先高精度档位。专家意见可信度：W8A8 高、W4A4 中（纯文本 dense 实践少）。

---

## 9. 结构模型类通用处理顺序

1. 固化基线 YAML；取完整 `named_modules`，把结构映射到模型类（可多属）。
2. 先覆盖「明确保持高精度」的特殊结构：DSA/SWA/GatedDeltaNet、VLM/扩散的 `merger`/`mod` 排除。
3. 处理 MoE `gate`/`router`、`shared_experts` 高精度档位。
4. 按格式确定低比特落点（W4A8/W4A4 的 experts）与敏感层专家提级。
5. 处理 MLA 低秩投影与 `mlp.down_proj` / `o_proj` 等结构化回退候选。
6. 最后才基于敏感层分析处理普通 attention/FFN 主体，不做整体盲退。

每次只引入可追踪的结构化变更，记录层号与专家意见可信度；不同结构的层号与模块前缀**不得直接合并**。