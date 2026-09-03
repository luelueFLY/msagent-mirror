# Smoothing-family 图关系参考

参考各 processor 接口需要表达的图关系：

| Processor | 接口 |
|---|---|
| `flex_smooth_quant`, `flex_awq_ssz` | `FlexSmoothQuantInterface` |
| `iter_smooth` | `IterSmoothInterface` |
| `smooth_quant` | `SmoothQuantInterface` |
| `oasq` | `OASQInterface` |

从官方 `ComputationGraph` 分析 norm-linear、OV、up-down、linear-linear 或有充分理由的
non-fusion 关系。

官方计算图核对应覆盖：

- 接口所需关系是否可由当前拓扑表达；
- 代表性 source/target 对及支持的 subgraph 类型；
- 从源码推导的 channel dimension 和专用元数据；
- 独立定义的共享输入、dense、routed expert 和 shared expert 覆盖范围；
- 重复/冲突条目以及 include/exclude 的效果；
- 无法静态确认的动态关系与限制。

本阶段固定适配默认 smoothing 算法：完成必要 `AdapterConfig` 映射、调用对应 processor，
并按 `validation.md` 比较变换前后浮点模型最终 logits。不得追加线性量化 processor，也
不得生成 Practice。

默认配置从 msModelSlim 自带 `expert_experience.yaml` 的同名 `*_default` 模板读取。
`flex_awq_ssz_default.qconfig` 是该算法内部调用真实 quantizer 估计平滑误差的必填参数；
保留它不等于运行 `linear_quant`，独立校验的前后模型仍均为浮点模型。
