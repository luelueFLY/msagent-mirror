# 基准任务映射

必须使用当前仓库中的准确 AISBench 数据集任务名。用户只提供基准别名时，选择下表中的首选任务。用户明确给出任务名时，通过 `--search` 确认后保持原值。

## 验收范围内的基准

| 用户可能使用的名称 | 首选数据集任务 | 提示词格式 | 仓库根目录下所需数据 | 说明 |
| --- | --- | --- | --- | --- |
| `aime2025`、`AIME 2025`、`AIME-2025` | `aime2025_gen_0_shot_chat_prompt` | 对话 | `ais_bench/datasets/aime2025/aime2025.jsonl` | 0-shot 生成式测评，指标为 accuracy，最终答案从 `\boxed{}` 中提取。除非用户明确要求裁判模型测评并提供裁判模型配置，否则不得选择 `aime2025_gen_0_shot_llmjudge`。 |
| `aime2026`、`AIME 2026`、`AIME-2026` | `aime2026_gen_0_shot_chat_prompt` | 对话 | `ais_bench/datasets/aime2026/aime2026.jsonl` | 0-shot 生成式测评，指标为 accuracy，最终答案从 `\boxed{}` 中提取。 |
| `gpqa diamond`、`gpqa-diamond`、`gpqa_diamond`，以及未指定子集的 `gpqa` | `gpqa_gen_0_shot_cot_chat_prompt` | 对话 | `ais_bench/datasets/gpqa/gpqa_diamond.csv` | 当前仓库配置只启用 Diamond 子集，指标为 accuracy/pass@1，模型回答的最后一行应包含 `Answer: <LETTER>`。 |

以上三个首选任务都使用对话提示词。对于兼容 vLLM/OpenAI 的 Chat Completions 服务，可以统一搭配 `vllm_api_general_chat`。

数据集参数示例：

```text
--datasets aime2025_gen_0_shot_chat_prompt
--datasets aime2026_gen_0_shot_chat_prompt
--datasets gpqa_gen_0_shot_cot_chat_prompt
--datasets aime2025_gen_0_shot_chat_prompt aime2026_gen_0_shot_chat_prompt gpqa_gen_0_shot_cot_chat_prompt
```

## 其他标准基准

以下映射覆盖项目需求中提到的常见提示词。除非用户要求其他推理方式，否则对话模型优先选择对应的对话提示词任务。

| 用户可能使用的名称 | 首选数据集任务 | 提示词格式 | 数据要求 |
| --- | --- | --- | --- |
| `mmlu` | `mmlu_gen_5_shot_chat_prompt` | 对话 | 读取 `ais_bench/benchmark/configs/datasets/mmlu/README.md`；MMLU 包含多个学科文件。 |
| `gsm8k` | `gsm8k_gen_4_shot_cot_chat_prompt` | 对话 | 读取 `ais_bench/benchmark/configs/datasets/gsm8k/README.md`，确认数据部署结构。 |
| `humaneval`、`human eval` | `humaneval_gen_0_shot` | 字符串 | 读取 `ais_bench/benchmark/configs/datasets/humaneval/README.md`；应使用 `vllm_api_general` 等支持字符串格式的模型任务，不得直接套用上面的对话模型默认值。 |

## 选择规则

- “全量”表示不传 `--num-prompts`，而不是选择某个特殊的数据集任务。
- “抽样”“前 N 条”或“先跑 N 条”映射为 `--num-prompts N`；AISBench 会按数据集顺序选取前 N 条。
- 多个基准的提示词格式与所选模型任务兼容时，可以在同一个 `--datasets` 后传入多个数据集任务。
- “只推理”映射为 `--mode infer`。普通的“评测”映射为 `--mode all`，不能只执行 `infer`。
- “基于已有结果评估”需要使用 `--mode eval`，并提供用户指定或能够唯一确定的 `--reuse` 时间戳。
- “GPQA Diamond”是数据集子集，不是名为 `gpqa_diamond` 的 AISBench 数据集任务；应使用上表中的配置任务。
- 对映射表以外的基准，必须根据仓库中的 README 和配置文件确定任务名，不能根据基准名称自行拼接任务名。
