# 图配置留痕

无需生成独立能力审计 JSON。结构来源以已安装 msModelSlim `fast_ops_grapher` 为每项算法
生成的 `anti_outlier_graph.<algorithm>.dot` 为准，并在 `anti_outlier_report.md` 中记录所用
Extractor、模型路径、dummy input、设备和已安装包版本（可取得时记录 revision）。

报告把逐算法 DOT 图和各算法 `final_logits_comparison.<algorithm>.json` 列入普通
`artifact_paths`，并记录用户选择以及实际 processor/logits 门禁步骤。不得新增
capability matrix 或调优策略字段，不得把用户选择本身写成验证通过。报告还须说明每项
算法是否从同一原始浮点 checkpoint 重新加载干净模型，以及是否只应用了当前 processor。
