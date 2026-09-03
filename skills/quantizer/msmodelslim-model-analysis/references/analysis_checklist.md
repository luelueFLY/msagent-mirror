# 分析检查清单

在开始实现适配器前使用本清单。

## 1）实现来源

- [ ] 读取 `config.json`
- [ ] 按以下优先级解析实现来源（命中其一即可）：
  - [ ] `transformers/models/<model_type>/modeling_<model_type>.py` → `transformers`
  - [ ] 通过 `auto_map` 定位模型目录内 `modeling_*.py` → `model-local`
  - [ ] 模型目录或一级子目录下 `*.json` 含 `_diffusers_version` 字段 → `diffusers`（DiT 扩散）
- [ ] 若以上路径均未命中，停止并要求用户提供实现代码
- [ ] DiT 路径下：必须由用户额外提供**推理仓路径**（与权重目录分离），仅做"路径存在且为目录"校验

## 2）模型类型、结构差异与连接关系（相对常见 Qwen2）

- [ ] 判定模型类型：纯 LLM / 多模态理解模型 / DiT 扩散
- [ ] 若为多模态理解模型，确认仅分析文本主干范围
- [ ] 若为 DiT 扩散，记录以下字段：
  - [ ] `model_family`（`dit`）
  - [ ] `inference_repo`（用户提供的绝对路径）
  - [ ] `apiversion`：固定 `multimodal_sd_modelslim_v1`
  - [ ] `quant_service`：固定 `MultimodalSDModelslimV1QuantService`
  - [ ] 条件注入路径、时间步嵌入位置、attention 类型清单
  - [ ] 双专家结构（是/否）
- [ ] 记录相对常见 Qwen2 的特殊结构设计及可能影响
- [ ] 记录特殊结构连接关系（接入位置、前后依赖、串联/并联/残差）及其对遍历/forward 的影响

## 3）结构特征

- [ ] 确认 decoder 层类
- [ ] 确认 attention 与 MLP 模块命名
- [ ] 确认 forward 签名与关键返回值
- [ ] 确认用于遍历的层容器路径

## 4）逐层量化建议（可选高阶特性）

- [ ] 评估全量加载内存与当前环境
- [ ] 决定是否建议逐层量化（按层加载）
- [ ] 记录理由与预期影响
- [ ] 若建议启用，备注：先完成基础适配与四步验证，再进入 `msmodelslim-layer-wise-quantization`

## 5）MoE 融合风险

- [ ] 判断模型是否含 MoE
- [ ] 若含 MoE，检查专家权重布局（独立线性层 vs 打包张量）
- [ ] 检查 `gate/up/down` 是否存在按 expert 维度打包的 3D 权重
- [ ] 标记为：无 MoE / MoE 非融合 / MoE 融合
- [ ] 记录可能的 unpack 需求

## 6）适配影响要点

- [ ] 记录 `generate_model_visit` 的遍历顺序预期
- [ ] 记录 `generate_model_forward` 的对齐约束
- [ ] 列出可能影响权重一致性检查的风险模块

## 7）量化模型风险（反量化脚本）

- [ ] 判断模型是否“本身已量化”
- [ ] 若已量化，要求用户主动提供反量化脚本
- [ ] 若用户未提供反量化脚本，标记为阻塞并停止后续适配实现

## 8）MTP 结构风险（实现缺失）

- [ ] 判断模型是否包含 MTP 结构
- [ ] 若存在 MTP，检查是否能获取 MTP 实现代码
- [ ] 若无法获取实现代码，明确告知 agent 可能无法完整实现 MTP 结构适配
- [ ] 若用户仍需继续，提示用户需自行复制 MTP 权重
