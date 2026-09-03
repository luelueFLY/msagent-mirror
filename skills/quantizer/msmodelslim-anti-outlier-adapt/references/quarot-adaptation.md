# QuaRot 图关系参考

参考 `QuaRotInterface` 的 `get_ln_fuse_map`、`get_bake_names` 和
`get_rotate_map(block_size)` 所需语义，整理图节点、图边和约束。

从目标源码推导映射，包括残差流生产者/消费者、embedding/head 关系、attention 与
MLP projection、融合分区、可寻址 expert、视觉融合输入和辅助 decoder 路径。根据
被变换权重的维度推导左乘或右乘。只有目标 norm 语义确有需要时才执行 mean bake；
不得在没有证据时把 LayerNorm 规则套用到 RMSNorm。

从官方 `ComputationGraph` 核对：

- 接口所需的关系是否可由当前拓扑表达；
- 代表性的 norm fusion、bake、全局和局部旋转映射；
- 从源码推导的 target side、维度和融合切分；
- 独立定义的 dense、expert 或辅助分支覆盖范围；
- 重复或冲突的 target-side 条目；
- 目标特定的非法 block size 和 shape 行为。

本阶段固定适配 QuaRot：完成必要映射、调用真实 processor，并按 `validation.md` 比较变换前后浮点模型最终 logits。
不得追加量化 processor。在线/离线模式、合法 block size/shape 和实际参数须写入验证记录。
