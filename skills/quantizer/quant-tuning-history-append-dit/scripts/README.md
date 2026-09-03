# scripts/

| Script | Purpose |
|---|---|
| [`append.py`](append.py) | Append (or upsert) one DiT-tuning round record to `{workdir}/history/history.yaml`. Idempotent on `practice_id`. |

## Quick start

```bash
python scripts/append.py \
    --history-path /path/to/history.yaml \
    --practice-id dit-round-2 \
    --practice-path /path/to/round_2/practice.yaml \
    --inference-outputs "/path/to/infer_outputs/round_2/overall_consistency/0000.mp4,/path/to/infer_outputs/round_2/subject_consistency/0001.mp4"
```

## Module surface

```python
from append import append_dit_record

record = append_dit_record(
    history_path="{workdir}/history/history.yaml",
    practice_id="dit-round-2",
    practice_path="{workdir}/round_2/practice.yaml",
    inference_outputs=[".../0000.mp4", ".../0001.mp4"],
    fp_baseline_outputs=None,        # only if quant-tuning-evaluate DiT workflow ran in FP baseline mode
    scores=None,                     # filled by quant-tuning-score-dit
    overall_score=None,              # filled by quant-tuning-score-dit
    loss_vs_baseline=None,           # filled by quant-tuning-score-dit when --baseline-outputs is enabled
    is_satisfied=None,               # filled by quant-tuning-score-dit; orchestrator reads it as exit signal
)
```

## Conventions

* **YAML section name** defaults to `dit_records`; LLM/VLM records stay under the original `records` key — the two coexist in the same file.
* **Upsert semantics**: re-running with the same `practice_id` overwrites the previous entry, never duplicates it.
* **Scoring fields** (`scores` / `overall_score` / `loss_vs_baseline` / `is_satisfied`) are populated by `quant-tuning-score-dit` and passed in via flags `--scores-json` / `--overall-score` / `--loss-vs-baseline` / `--is-satisfied`. If scoring was not triggered this round they remain `null`.
