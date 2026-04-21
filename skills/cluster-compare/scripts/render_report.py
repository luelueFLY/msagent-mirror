#!/usr/bin/env python3
"""Render the final HTML report from LLM JSON output and a Jinja2 template."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict

from jinja2 import Environment, FileSystemLoader, select_autoescape


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    base_dir = script_dir.parent
    default_output = base_dir / "output" / "final_report.html"

    parser = argparse.ArgumentParser(
        description="Render the cluster comparison HTML report with Jinja2."
    )
    parser.add_argument(
        "--input",
        required=True,
        help="LLM 生成的 JSON 文件路径",
    )
    parser.add_argument(
        "--output",
        default=str(default_output),
        help="输出 HTML 文件路径，默认写入 output/final_report.html",
    )
    parser.add_argument(
        "--template",
        default="report_template.html",
        help="assets/ 目录中的模板文件名，默认 report_template.html",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON 解析失败，请检查 LLM 输出是否为合法 JSON: {exc}") from exc


def validate_payload(payload: Dict[str, Any]) -> None:
    required_fields = ["title", "summary", "meta_info", "blocks"]
    missing = [field for field in required_fields if field not in payload]
    if missing:
        raise ValueError(f"缺少必填字段: {', '.join(missing)}")

    if not isinstance(payload["meta_info"], list):
        raise ValueError("meta_info 必须是数组")
    if not isinstance(payload["blocks"], list):
        raise ValueError("blocks 必须是数组")

    for index, block in enumerate(payload["blocks"], start=1):
        if not isinstance(block, dict):
            raise ValueError(f"blocks[{index}] 必须是对象")
        block_type = block.get("type")
        if block_type not in {"kpi_grid", "chart", "analysis_text"}:
            raise ValueError(f"blocks[{index}] 的 type 无效: {block_type}")


def render_report(
    json_payload: Dict[str, Any],
    template_dir: Path,
    template_name: str,
) -> str:
    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        autoescape=select_autoescape(["html", "xml"]),
    )
    template = env.get_template(template_name)
    return template.render(**json_payload)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    script_dir = Path(__file__).resolve().parent
    template_dir = script_dir.parent / "assets"

    if not input_path.exists():
        raise FileNotFoundError(f"未找到输入 JSON: {input_path}")

    payload = load_json(input_path)
    validate_payload(payload)
    html = render_report(payload, template_dir, args.template)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html, encoding="utf-8")
    print(f"HTML report written to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
