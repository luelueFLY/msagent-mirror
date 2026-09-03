# scripts/

Tooling that applies the experience library's recommendations to concrete artifacts.

| Script | Purpose |
|---|---|
| [`apply_rollback.py`](apply_rollback.py) | DiT block rollback — translate a `first_n_blocks` (or `block_indices`) value into `*<container>.{i}.*` exclude entries, append them to a base Practice YAML, write the result. Auto-detects block-container name from the existing exclude list. Computes output `md5` for orchestrator-level dedup. |
| [`yaml_utils.py`](yaml_utils.py) | Thin YAML I/O helpers — `load_yaml`, `dump_yaml`, `find_exclude_target`, `merge_exclude`. No Pydantic / no msmodelslim dependency; PyYAML is the only requirement. |
| [`inspect_model_structure.py`](inspect_model_structure.py) | **DEPRECATED** — kept for legacy debug only. DiT tuning no longer scans `inference_repo`; `block_container` is auto-detected and structural patterns live in [`../structure-family-pitfalls.md` §7](../structure-family-pitfalls.md). |

## Quick start — DiT block rollback

```bash
# Apply block rollback (single-dimension input)
python scripts/apply_rollback.py \
    --base-practice output/wan22-t2v-a14b-w8a8/w8a8_config.yaml \
    --first-n-blocks 5 \
    --output-practice output/wan22-t2v-a14b-w8a8/round_2/practice.yaml
```

`--first-n-blocks 5` 产出（**整块回退**，每条覆盖 block {i} 下所有子模块）：

```yaml
exclude:
  - "*blocks.0.*"   # block 0 整块（attn + ffn + norm + modulation）
  - "*blocks.1.*"   # block 1 整块
  - "*blocks.2.*"   # block 2 整块
  - "*blocks.3.*"   # block 3 整块
  - "*blocks.4.*"   # block 4 整块
```

> 关键 glob 形态：`<container>.{i}.*` —— 点号分隔保证只命中该 block 内的层，不污染相邻 block 或顶层模块。

Defaults come from [`../structure-family-pitfalls.md` §7](../structure-family-pitfalls.md):

| Model family | `first_n_blocks` |
|---|---|
| Wan2.2-T2V-A14B / I2V-A14B | 5 |
| Wan2.2-TI2V-5B | 3 |
| Wan2.1-T2V-14B | 5 |
| FLUX.1-dev | 5 |
| HunyuanVideo | 8 |
| SD3 / Sana / HunyuanDiT / CogViewX | 5 |

## Module surfaces

```python
from yaml_utils import load_yaml, dump_yaml, merge_exclude, find_exclude_target
from apply_rollback import apply_rollback, RollbackRules
```

## Conventions

* `apply_rollback` is **side-effect-only-on-output**: it writes the merged YAML but never touches the input.
* `merge_exclude` deduplicates against the existing exclude list — repeated entries are dropped.
* Block-container name resolution order: explicit `--block-container` > first match in existing exclude list (`blocks` / `transformer_blocks` / `single_transformer_blocks`) > default `blocks`.

## Anti-patterns

* ❌ Don't pass `by_pattern` / `by_op` — only `first_n_blocks` and `block_indices` are accepted. Structural patterns (`*ffn.down*` / `*attn.out_proj*` / modulation) live in the experience library, not in this script.
* ❌ Don't run `inspect_model_structure.py` to decide rollback rules — it's deprecated; read the experience library instead.
* ❌ Don't write the result to a file outside `{workdir}/round_{N}/practice.yaml` — breaks the orchestrator history lookup.