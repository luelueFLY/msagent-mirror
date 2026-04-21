#!/usr/bin/env python3
"""Extract structured evidence for cluster comparison reports."""

from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


BANDWIDTH_TYPES = ["HCCS", "RDMA", "SDMA", "SIO"]
SUMMARY_METRICS = [
    ("avg_stage_ms", "Stage 总耗时", "ms", True),
    ("avg_computing_ms", "计算耗时", "ms", True),
    ("avg_communication_ms", "通信耗时-总", "ms", True),
    ("avg_comm_not_overlap_ms", "通信耗时-未重叠", "ms", True),
    ("avg_free_ms", "空闲耗时", "ms", True),
    ("avg_overlapped_ms", "重叠耗时", "ms", False),
]
OP_METRICS = [
    ("avg_elapsed_ms", "平均总耗时", "ms", True),
    ("avg_wait_ms", "平均等待耗时", "ms", True),
    ("avg_sync_ms", "平均同步耗时", "ms", True),
    ("avg_transit_ms", "平均传输耗时", "ms", True),
]
TRANSPORT_METRICS = [
    ("avg_bandwidth", "平均带宽", "GB/s", False),
    ("avg_transit_size_mb", "平均传输大小", "MB", False),
    ("avg_transit_time_ms", "平均传输耗时", "ms", True),
]


class ClusterAnalyzer:
    def __init__(self, db_path: Path, cluster_name: str):
        self.db_path = db_path
        self.cluster_name = cluster_name
        self.conn: Optional[sqlite3.Connection] = None

    def connect(self) -> None:
        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.row_factory = sqlite3.Row

    def close(self) -> None:
        if self.conn:
            self.conn.close()

    def _execute_query(
        self,
        sql: str,
        params: Optional[Iterable[Any]] = None,
    ) -> List[Dict[str, Any]]:
        if not self.conn:
            raise RuntimeError("Database connection is not open")
        cursor = self.conn.cursor()
        if params is None:
            cursor.execute(sql)
        else:
            cursor.execute(sql, tuple(params))
        columns = [desc[0] for desc in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]

    def get_basic_info(self) -> Dict[str, Any]:
        rank_count = self._execute_query(
            "SELECT COUNT(DISTINCT rankId) AS count FROM RankDeviceMap"
        )[0]["count"]
        host_count = self._execute_query(
            "SELECT COUNT(*) AS count FROM HostInfo"
        )[0]["count"]
        steps = self._execute_query(
            "SELECT DISTINCT step FROM ClusterStepTraceTime WHERE type='rank' ORDER BY step"
        )

        return {
            "cluster_name": self.cluster_name,
            "rank_count": rank_count,
            "host_count": host_count,
            "steps": [row["step"] for row in steps],
        }

    def get_step_trace_metrics(self, step: Optional[str]) -> Dict[str, Any]:
        sql = """
        SELECT
            AVG(computing) AS avg_computing,
            AVG(communication_not_overlapped) AS avg_comm_not_overlap,
            AVG(communication) AS avg_communication,
            AVG(free) AS avg_free,
            AVG(stage) AS avg_stage,
            AVG(overlapped) AS avg_overlapped,
            COUNT(*) AS rank_count
        FROM ClusterStepTraceTime
        WHERE type = 'rank'
        """
        params: List[Any] = []
        if step:
            sql += " AND step = ?"
            params.append(step)
        row = self._execute_query(sql, params)[0]

        return {
            "avg_computing_ms": micros_to_ms(row["avg_computing"]),
            "avg_comm_not_overlap_ms": micros_to_ms(row["avg_comm_not_overlap"]),
            "avg_communication_ms": micros_to_ms(row["avg_communication"]),
            "avg_free_ms": micros_to_ms(row["avg_free"]),
            "avg_stage_ms": micros_to_ms(row["avg_stage"]),
            "avg_overlapped_ms": micros_to_ms(row["avg_overlapped"]),
            "rank_count": row["rank_count"],
        }

    def get_bandwidth_stats(self) -> Dict[str, Dict[str, Any]]:
        rows = self._execute_query(
            """
            SELECT
                band_type,
                COUNT(*) AS count,
                AVG(bandwidth) AS avg_bandwidth,
                MAX(bandwidth) AS max_bandwidth,
                MIN(bandwidth) AS min_bandwidth,
                AVG(transit_size) AS avg_transit_size,
                AVG(transit_time) AS avg_transit_time
            FROM ClusterCommunicationBandwidth
            GROUP BY band_type
            """
        )

        stats: Dict[str, Dict[str, Any]] = {}
        for row in rows:
            band_type = row["band_type"]
            stats[band_type] = {
                "count": row["count"],
                "avg_bandwidth": round_or_zero(row["avg_bandwidth"]),
                "max_bandwidth": round_or_zero(row["max_bandwidth"]),
                "min_bandwidth": round_or_zero(row["min_bandwidth"]),
                "avg_transit_size_mb": round_or_zero(row["avg_transit_size"]),
                "avg_transit_time_ms": micros_to_ms(row["avg_transit_time"]),
            }
        return stats

    def get_transport_stats(self) -> Dict[str, Dict[str, Any]]:
        rows = self._execute_query(
            """
            SELECT
                transport_type,
                COUNT(*) AS count,
                AVG(CAST(bandwidth AS REAL)) AS avg_bandwidth,
                AVG(transit_size) AS avg_transit_size,
                AVG(transit_time) AS avg_transit_time
            FROM ClusterCommunicationMatrix
            GROUP BY transport_type
            """
        )

        stats: Dict[str, Dict[str, Any]] = {}
        for row in rows:
            transport_type = row["transport_type"]
            stats[transport_type] = {
                "count": row["count"],
                "avg_bandwidth": round_or_zero(row["avg_bandwidth"]),
                "avg_transit_size_mb": round_or_zero(row["avg_transit_size"]),
                "avg_transit_time_ms": micros_to_ms(row["avg_transit_time"]),
            }
        return stats

    def get_op_type_stats(self, step: Optional[str]) -> Dict[str, Dict[str, Any]]:
        sql = """
        SELECT
            CASE
                WHEN hccl_op_name LIKE '%allReduce%' THEN 'allReduce'
                WHEN hccl_op_name LIKE '%allGather%' THEN 'allGather'
                WHEN hccl_op_name LIKE '%reduceScatter%' THEN 'reduceScatter'
                WHEN hccl_op_name LIKE '%batchSendRecv%' THEN 'batchSendRecv'
                WHEN hccl_op_name LIKE '%broadcast%' THEN 'broadcast'
                WHEN hccl_op_name LIKE '%alltoall%' THEN 'alltoall'
                ELSE 'other'
            END AS op_type,
            COUNT(*) AS count,
            AVG(elapsed_time) AS avg_elapsed,
            AVG(wait_time) AS avg_wait,
            AVG(synchronization_time) AS avg_sync,
            AVG(transit_time) AS avg_transit
        FROM ClusterCommunicationTime
        """
        params: List[Any] = []
        if step:
            sql += " WHERE step = ?"
            params.append(step)
        sql += " GROUP BY op_type ORDER BY avg_elapsed DESC"
        rows = self._execute_query(sql, params)

        stats: Dict[str, Dict[str, Any]] = {}
        for row in rows:
            op_type = row["op_type"]
            stats[op_type] = {
                "count": row["count"],
                "avg_elapsed_ms": micros_to_ms(row["avg_elapsed"]),
                "avg_wait_ms": micros_to_ms(row["avg_wait"]),
                "avg_sync_ms": micros_to_ms(row["avg_sync"]),
                "avg_transit_ms": micros_to_ms(row["avg_transit"]),
            }
        return stats

    def get_named_hotspots(
        self,
        step: Optional[str],
        limit: int = 8,
    ) -> List[Dict[str, Any]]:
        sql = """
        SELECT
            hccl_op_name,
            AVG(elapsed_time) AS avg_elapsed,
            AVG(wait_time) AS avg_wait,
            AVG(transit_time) AS avg_transit,
            COUNT(*) AS count
        FROM ClusterCommunicationTime
        """
        params: List[Any] = []
        if step:
            sql += " WHERE step = ?"
            params.append(step)
        sql += " GROUP BY hccl_op_name ORDER BY avg_elapsed DESC LIMIT ?"
        params.append(limit)
        rows = self._execute_query(sql, params)

        return [
            {
                "hccl_op_name": row["hccl_op_name"],
                "count": row["count"],
                "avg_elapsed_ms": micros_to_ms(row["avg_elapsed"]),
                "avg_wait_ms": micros_to_ms(row["avg_wait"]),
                "avg_transit_ms": micros_to_ms(row["avg_transit"]),
            }
            for row in rows
        ]


def micros_to_ms(value: Optional[float]) -> float:
    if not value:
        return 0.0
    return round(float(value) / 1000.0, 4)


def round_or_zero(value: Optional[float], digits: int = 4) -> float:
    if value is None:
        return 0.0
    return round(float(value), digits)


def compare_values(
    label: str,
    normal: float,
    abnormal: float,
    unit: str,
    higher_is_worse: bool,
    description: str,
) -> Dict[str, Any]:
    delta = round(float(abnormal) - float(normal), 4)
    delta_pct = None
    if normal != 0:
        delta_pct = round((delta / float(normal)) * 100.0, 4)

    if abs(delta) < 1e-9:
        status = "flat"
    elif higher_is_worse:
        status = "regression" if delta > 0 else "improvement"
    else:
        status = "regression" if delta < 0 else "improvement"

    return {
        "label": label,
        "description": description,
        "unit": unit,
        "higher_is_worse": higher_is_worse,
        "normal": round(float(normal), 4),
        "abnormal": round(float(abnormal), 4),
        "delta": delta,
        "delta_pct": delta_pct,
        "status": status,
    }


def build_summary_metrics(
    normal_data: Dict[str, Any],
    abnormal_data: Dict[str, Any],
) -> Dict[str, Dict[str, Any]]:
    metrics: Dict[str, Dict[str, Any]] = {}
    descriptions = {
        "avg_stage_ms": "Step 平均整体耗时",
        "avg_computing_ms": "Step 平均计算耗时",
        "avg_communication_ms": "Step 平均总通信耗时",
        "avg_comm_not_overlap_ms": "Step 平均未重叠通信耗时",
        "avg_free_ms": "Step 平均空闲耗时",
        "avg_overlapped_ms": "Step 平均重叠耗时",
    }
    for key, label, unit, higher_is_worse in SUMMARY_METRICS:
        metrics[key] = compare_values(
            label=label,
            normal=normal_data[key],
            abnormal=abnormal_data[key],
            unit=unit,
            higher_is_worse=higher_is_worse,
            description=descriptions[key],
        )
    return metrics


def build_bandwidth_metrics(
    normal_data: Dict[str, Dict[str, Any]],
    abnormal_data: Dict[str, Dict[str, Any]],
) -> Dict[str, Dict[str, Any]]:
    metrics: Dict[str, Dict[str, Any]] = {}
    for band_type in BANDWIDTH_TYPES:
        normal_band = normal_data.get(band_type, {})
        abnormal_band = abnormal_data.get(band_type, {})
        metrics[band_type] = compare_values(
            label=f"{band_type} 平均带宽",
            normal=normal_band.get("avg_bandwidth", 0.0),
            abnormal=abnormal_band.get("avg_bandwidth", 0.0),
            unit="GB/s",
            higher_is_worse=False,
            description=f"{band_type} 链路平均带宽",
        )
        metrics[band_type]["normal_count"] = normal_band.get("count", 0)
        metrics[band_type]["abnormal_count"] = abnormal_band.get("count", 0)
        metrics[band_type]["normal_transit_size_mb"] = normal_band.get(
            "avg_transit_size_mb", 0.0
        )
        metrics[band_type]["abnormal_transit_size_mb"] = abnormal_band.get(
            "avg_transit_size_mb", 0.0
        )
    return metrics


def build_transport_metrics(
    normal_data: Dict[str, Dict[str, Any]],
    abnormal_data: Dict[str, Dict[str, Any]],
) -> Dict[str, Dict[str, Dict[str, Any]]]:
    metric_ids = set(normal_data.keys()) | set(abnormal_data.keys())
    results: Dict[str, Dict[str, Dict[str, Any]]] = {}
    for transport_type in sorted(metric_ids):
        metrics_by_type: Dict[str, Dict[str, Any]] = {}
        normal_transport = normal_data.get(transport_type, {})
        abnormal_transport = abnormal_data.get(transport_type, {})
        for key, label, unit, higher_is_worse in TRANSPORT_METRICS:
            metrics_by_type[key] = compare_values(
                label=f"{transport_type} {label}",
                normal=normal_transport.get(key, 0.0),
                abnormal=abnormal_transport.get(key, 0.0),
                unit=unit,
                higher_is_worse=higher_is_worse,
                description=f"{transport_type} 传输维度的{label}",
            )
        metrics_by_type["count"] = compare_values(
            label=f"{transport_type} 记录数",
            normal=normal_transport.get("count", 0),
            abnormal=abnormal_transport.get("count", 0),
            unit="条",
            higher_is_worse=False,
            description=f"{transport_type} 传输记录数量",
        )
        results[transport_type] = metrics_by_type
    return results


def build_op_metrics(
    normal_data: Dict[str, Dict[str, Any]],
    abnormal_data: Dict[str, Dict[str, Any]],
) -> Dict[str, Dict[str, Dict[str, Any]]]:
    op_types = set(normal_data.keys()) | set(abnormal_data.keys())
    results: Dict[str, Dict[str, Dict[str, Any]]] = {}
    for op_type in sorted(op_types):
        metrics_by_type: Dict[str, Dict[str, Any]] = {}
        normal_op = normal_data.get(op_type, {})
        abnormal_op = abnormal_data.get(op_type, {})
        metrics_by_type["count"] = compare_values(
            label=f"{op_type} 记录数",
            normal=normal_op.get("count", 0),
            abnormal=abnormal_op.get("count", 0),
            unit="条",
            higher_is_worse=False,
            description=f"{op_type} 的统计记录数量",
        )
        for key, label, unit, higher_is_worse in OP_METRICS:
            metrics_by_type[key] = compare_values(
                label=f"{op_type} {label}",
                normal=normal_op.get(key, 0.0),
                abnormal=abnormal_op.get(key, 0.0),
                unit=unit,
                higher_is_worse=higher_is_worse,
                description=f"{op_type} 的{label}",
            )
        results[op_type] = metrics_by_type
    return results


def score_metric(metric: Dict[str, Any]) -> float:
    if metric["status"] != "regression":
        return -1.0
    if metric["delta_pct"] is not None:
        return abs(metric["delta_pct"])
    return abs(metric["delta"])


def make_evidence_entry(metric_id: str, metric: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "metric_id": metric_id,
        "label": metric["label"],
        "status": metric["status"],
        "delta": metric["delta"],
        "delta_pct": metric["delta_pct"],
        "unit": metric["unit"],
        "summary": describe_metric(metric),
    }


def build_evidence_lists(report_data: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    summary_candidates = [
        ("summary." + key, metric)
        for key, metric in report_data["summary_metrics"].items()
    ]
    bandwidth_candidates = [
        ("bandwidth." + key, metric)
        for key, metric in report_data["bandwidth_by_type"].items()
    ]

    op_elapsed_candidates = [
        (f"op_elapsed.{op_type}", metrics["avg_elapsed_ms"])
        for op_type, metrics in report_data["op_metrics_by_type"].items()
    ]
    op_wait_candidates = [
        (f"op_wait.{op_type}", metrics["avg_wait_ms"])
        for op_type, metrics in report_data["op_metrics_by_type"].items()
    ]

    def top_entries(
        candidates: List[tuple[str, Dict[str, Any]]],
        limit: int = 6,
    ) -> List[Dict[str, Any]]:
        ranked = sorted(candidates, key=lambda item: score_metric(item[1]), reverse=True)
        return [
            make_evidence_entry(metric_id, metric)
            for metric_id, metric in ranked
            if metric["status"] == "regression"
        ][:limit]

    return {
        "largest_summary_regressions": top_entries(summary_candidates),
        "largest_bandwidth_drops": top_entries(bandwidth_candidates),
        "largest_op_elapsed_regressions": top_entries(op_elapsed_candidates),
        "largest_op_wait_regressions": top_entries(op_wait_candidates),
    }


def build_metric_catalog(report_data: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    catalog: Dict[str, Dict[str, Any]] = {}
    for key, metric in report_data["summary_metrics"].items():
        catalog[f"summary.{key}"] = metric
    for key, metric in report_data["bandwidth_by_type"].items():
        catalog[f"bandwidth.{key}"] = metric
    for transport_type, metrics in report_data["transport_metrics_by_type"].items():
        for metric_name, metric in metrics.items():
            catalog[f"transport.{transport_type}.{metric_name}"] = metric
    for op_type, metrics in report_data["op_metrics_by_type"].items():
        for metric_name, metric in metrics.items():
            if metric_name == "count":
                catalog[f"op_count.{op_type}"] = metric
            else:
                prefix = metric_name.replace("avg_", "").replace("_ms", "")
                catalog[f"op_{prefix}.{op_type}"] = metric
    return catalog


def build_chart_catalog(report_data: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    normal_label = report_data["clusters"]["normal"]["cluster_name"]
    abnormal_label = report_data["clusters"]["abnormal"]["cluster_name"]

    time_breakdown = {
        "kind": "stacked_bar",
        "title": "时间分布对比",
        "description": "按计算、通信和空闲拆解两个集群的平均 Step 耗时。",
        "unit": "ms",
        "categories": [normal_label, abnormal_label],
        "series": [
            {
                "name": "计算耗时",
                "data": [
                    report_data["summary_metrics"]["avg_computing_ms"]["normal"],
                    report_data["summary_metrics"]["avg_computing_ms"]["abnormal"],
                ],
            },
            {
                "name": "未重叠通信",
                "data": [
                    report_data["summary_metrics"]["avg_comm_not_overlap_ms"]["normal"],
                    report_data["summary_metrics"]["avg_comm_not_overlap_ms"]["abnormal"],
                ],
            },
            {
                "name": "空闲耗时",
                "data": [
                    report_data["summary_metrics"]["avg_free_ms"]["normal"],
                    report_data["summary_metrics"]["avg_free_ms"]["abnormal"],
                ],
            },
        ],
    }

    bandwidth_compare = {
        "kind": "grouped_bar",
        "title": "带宽对比",
        "description": "按链路类型对比两个集群的平均带宽。",
        "unit": "GB/s",
        "categories": BANDWIDTH_TYPES,
        "series": [
            {
                "name": normal_label,
                "data": [
                    report_data["bandwidth_by_type"][band_type]["normal"]
                    for band_type in BANDWIDTH_TYPES
                ],
            },
            {
                "name": abnormal_label,
                "data": [
                    report_data["bandwidth_by_type"][band_type]["abnormal"]
                    for band_type in BANDWIDTH_TYPES
                ],
            },
        ],
    }

    top_ops = sorted(
        report_data["op_metrics_by_type"].items(),
        key=lambda item: max(
            item[1]["avg_elapsed_ms"]["normal"],
            item[1]["avg_elapsed_ms"]["abnormal"],
        ),
        reverse=True,
    )[:8]
    op_categories = [name for name, _ in top_ops]
    op_elapsed_compare = {
        "kind": "horizontal_bar",
        "title": "Top 通信操作耗时对比",
        "description": "按操作类型对比平均总耗时。",
        "unit": "ms",
        "categories": op_categories,
        "series": [
            {
                "name": normal_label,
                "data": [metrics["avg_elapsed_ms"]["normal"] for _, metrics in top_ops],
            },
            {
                "name": abnormal_label,
                "data": [metrics["avg_elapsed_ms"]["abnormal"] for _, metrics in top_ops],
            },
        ],
    }

    op_wait_compare = {
        "kind": "horizontal_bar",
        "title": "Top 通信等待耗时对比",
        "description": "按操作类型对比平均等待耗时。",
        "unit": "ms",
        "categories": op_categories,
        "series": [
            {
                "name": normal_label,
                "data": [metrics["avg_wait_ms"]["normal"] for _, metrics in top_ops],
            },
            {
                "name": abnormal_label,
                "data": [metrics["avg_wait_ms"]["abnormal"] for _, metrics in top_ops],
            },
        ],
    }

    return {
        "time_breakdown": time_breakdown,
        "bandwidth_compare": bandwidth_compare,
        "op_elapsed_compare": op_elapsed_compare,
        "op_wait_compare": op_wait_compare,
    }


def describe_metric(metric: Dict[str, Any]) -> str:
    if metric["status"] == "flat":
        return f"{metric['label']} 基本持平。"

    magnitude = abs(metric["delta"])
    magnitude_text = f"{magnitude:.2f} {metric['unit']}"
    pct = metric["delta_pct"]
    pct_text = "" if pct is None else f" ({abs(pct):.2f}%)"

    if metric["higher_is_worse"]:
        regression_word = "增加"
        improvement_word = "下降"
    else:
        regression_word = "下降"
        improvement_word = "提升"

    verb = regression_word if metric["status"] == "regression" else improvement_word
    return f"{metric['label']}{verb} {magnitude_text}{pct_text}。"


def build_report_data(
    normal_path: Path,
    abnormal_path: Path,
    step: Optional[str],
) -> Dict[str, Any]:
    analyzers = [
        ClusterAnalyzer(normal_path, "正常集群"),
        ClusterAnalyzer(abnormal_path, "异常集群"),
    ]
    try:
        for analyzer in analyzers:
            analyzer.connect()

        normal = {
            "basic_info": analyzers[0].get_basic_info(),
            "step_metrics": analyzers[0].get_step_trace_metrics(step),
            "bandwidth_stats": analyzers[0].get_bandwidth_stats(),
            "transport_stats": analyzers[0].get_transport_stats(),
            "op_stats": analyzers[0].get_op_type_stats(step),
            "named_hotspots": analyzers[0].get_named_hotspots(step),
        }
        abnormal = {
            "basic_info": analyzers[1].get_basic_info(),
            "step_metrics": analyzers[1].get_step_trace_metrics(step),
            "bandwidth_stats": analyzers[1].get_bandwidth_stats(),
            "transport_stats": analyzers[1].get_transport_stats(),
            "op_stats": analyzers[1].get_op_type_stats(step),
            "named_hotspots": analyzers[1].get_named_hotspots(step),
        }
    finally:
        for analyzer in analyzers:
            analyzer.close()

    report_data: Dict[str, Any] = {
        "metadata": {
            "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
            "step": step,
            "normal_db": str(normal_path),
            "abnormal_db": str(abnormal_path),
        },
        "clusters": {
            "normal": normal["basic_info"],
            "abnormal": abnormal["basic_info"],
        },
        "summary_metrics": build_summary_metrics(
            normal["step_metrics"], abnormal["step_metrics"]
        ),
        "bandwidth_by_type": build_bandwidth_metrics(
            normal["bandwidth_stats"], abnormal["bandwidth_stats"]
        ),
        "transport_metrics_by_type": build_transport_metrics(
            normal["transport_stats"], abnormal["transport_stats"]
        ),
        "op_metrics_by_type": build_op_metrics(
            normal["op_stats"], abnormal["op_stats"]
        ),
        "named_hotspots": {
            "normal": normal["named_hotspots"],
            "abnormal": abnormal["named_hotspots"],
        },
    }

    report_data["evidence_lists"] = build_evidence_lists(report_data)
    report_data["metric_catalog"] = build_metric_catalog(report_data)
    report_data["chart_catalog"] = build_chart_catalog(report_data)
    report_data["default_report_spec"] = {
        "title": "集群对比分析报告",
        "subtitle": "根据结构化证据生成的默认报告骨架，模型可以按需调整。",
        "summary": [
            "先阅读 evidence_lists 和 metric_catalog，再决定最关键的性能发现。",
            "保留模板风格稳定性，避免直接在 HTML 中硬编码结论或图表。",
        ],
        "sections": [
            {
                "type": "kpi_cards",
                "title": "核心指标",
                "items": [
                    "summary.avg_stage_ms",
                    "summary.avg_communication_ms",
                    "bandwidth.HCCS",
                    "bandwidth.RDMA",
                ],
            },
            {"type": "chart", "chart_id": "time_breakdown"},
            {
                "type": "findings",
                "title": "关键发现",
                "items": [
                    {
                        "title": "在这里写结论",
                        "severity": "medium",
                        "summary": "基于 report_data.json 里的证据重新生成，而不是照抄这份默认骨架。",
                        "evidence": ["引用 metric_catalog 或 evidence_lists 中的具体信号。"],
                    }
                ],
            },
            {"type": "chart", "chart_id": "bandwidth_compare"},
            {
                "type": "metric_table",
                "title": "关键指标对比",
                "items": [
                    "summary.avg_stage_ms",
                    "summary.avg_communication_ms",
                    "summary.avg_comm_not_overlap_ms",
                    "bandwidth.HCCS",
                    "bandwidth.SDMA",
                ],
            },
        ],
    }
    return report_data


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract structured evidence from two cluster_analysis.db files."
    )
    parser.add_argument("--normal", required=True, help="正常集群 cluster_analysis.db 路径")
    parser.add_argument("--abnormal", required=True, help="异常集群 cluster_analysis.db 路径")
    parser.add_argument("--output", required=True, help="输出 report_data.json 路径")
    parser.add_argument("--step", default=None, help="可选，只分析指定 step")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    normal_path = Path(args.normal).expanduser().resolve()
    abnormal_path = Path(args.abnormal).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    missing = [str(path) for path in [normal_path, abnormal_path] if not path.exists()]
    if missing:
        raise FileNotFoundError(f"Database file not found: {', '.join(missing)}")

    report_data = build_report_data(normal_path, abnormal_path, args.step)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(report_data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"Wrote structured evidence to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
