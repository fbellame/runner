#!/usr/bin/env python3
"""Report token consumption from local Claude Code and Codex CLI transcripts."""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import defaultdict
from datetime import date
from typing import Any, Iterable


CLAUDE_GLOB = "/Users/farid/.claude/projects/-Users-farid-projects-running/*.jsonl"
CODEX_GLOBS = (
    "/Users/farid/.codex/sessions/**/*.jsonl",
    "/Users/farid/.codex/archived_sessions/*.jsonl",
)

# USD per million tokens. Claude rates come from the claude-api skill's cached
# pricing table (SKILL.md "Current Models") plus its cache-economics multipliers
# (shared/prompt-caching.md: cache write = 1.25x input for the default 5-minute
# TTL, cache read = 0.1x input) -- as of 2026-06-24, see
# /Users/farid/.claude/plugins/marketplaces/anthropic-agent-skills/skills/claude-api/SKILL.md
# and .../shared/prompt-caching.md. A missing model uses __default__ (all zero).
PRICING = {
    "__default__": {
        "fresh_input": 0.00,
        "cache_created": 0.00,
        "cache_read": 0.00,
        "output": 0.00,
    },
    "claude-opus-4-8": {
        "fresh_input": 5.00,
        "cache_created": 6.25,
        "cache_read": 0.50,
        "output": 25.00,
    },
    "claude-fable-5": {
        "fresh_input": 10.00,
        "cache_created": 12.50,
        "cache_read": 1.00,
        "output": 50.00,
    },
    # For future subagent use -- not yet seen in this project's transcripts,
    # but priced so the report is correct if a subagent runs on these models.
    "claude-sonnet-5": {
        # Standard list price. Sonnet 5 has an introductory discount
        # ($2.00 input / $10.00 output per 1M) through 2026-08-31; using the
        # standard rate here so the estimate doesn't need updating after that.
        "fresh_input": 3.00,
        "cache_created": 3.75,
        "cache_read": 0.30,
        "output": 15.00,
    },
    "claude-haiku-4-5": {
        "fresh_input": 1.00,
        "cache_created": 1.25,
        "cache_read": 0.10,
        "output": 5.00,
    },
    "gpt-5.5": {
        "fresh_input": 0.00,
        "cache_created": 0.00,
        "cache_read": 0.00,
        "output": 0.00,
    },
    "gpt-5.6-sol": {
        # Codex is subscription-billed via ChatGPT; token counts only, no per-token cost.
        "fresh_input": 0.00,
        "cache_created": 0.00,
        "cache_read": 0.00,
        "output": 0.00,
    },
    "gpt-5.6-terra": {
        # Codex is subscription-billed via ChatGPT; token counts only, no per-token cost.
        "fresh_input": 0.00,
        "cache_created": 0.00,
        "cache_read": 0.00,
        "output": 0.00,
    },
}

TOKEN_FIELDS = ("fresh_input", "cache_created", "cache_read", "output")


def empty_totals() -> dict[str, int]:
    return {**{field: 0 for field in TOKEN_FIELDS}, "messages": 0}


def number(value: Any) -> int:
    """Return a non-negative integer from a log field without trusting its type."""
    return value if isinstance(value, int) and value >= 0 else 0


def record_date(record: dict[str, Any]) -> str | None:
    timestamp = record.get("timestamp")
    if isinstance(timestamp, str) and len(timestamp) >= 10:
        return timestamp[:10]
    return None


def in_range(day: str | None, since: str | None, until: str | None) -> bool:
    return day is not None and (since is None or day >= since) and (until is None or day <= until)


def add(target: dict[str, int], values: dict[str, int]) -> None:
    for field in (*TOKEN_FIELDS, "messages"):
        target[field] += values.get(field, 0)


def claude_usage(message: dict[str, Any]) -> dict[str, int]:
    usage = message.get("usage", {})
    if not isinstance(usage, dict):
        usage = {}
    return {
        "fresh_input": number(usage.get("input_tokens")),
        "cache_created": number(usage.get("cache_creation_input_tokens")),
        "cache_read": number(usage.get("cache_read_input_tokens")),
        "output": number(usage.get("output_tokens")),
        "messages": 1,
    }


def read_json_lines(paths: Iterable[str]) -> Iterable[tuple[str, dict[str, Any]]]:
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(item, dict):
                        yield path, item
        except OSError:
            continue


def derive_claude_glob(project_dir: str) -> str:
    """Derive the Claude Code transcript glob from a project directory path."""
    abs_path = os.path.abspath(project_dir)
    encoded_path = abs_path.replace("/", "-")
    return f"/Users/farid/.claude/projects/{encoded_path}/*.jsonl"


def claude_totals(since: str | None, until: str | None, claude_glob: str = CLAUDE_GLOB) -> dict[str, dict[str, int]]:
    """Keep only the final copy of each streamed/retried Claude assistant message."""
    final_messages: dict[tuple[str, str], tuple[str | None, str, dict[str, int]]] = {}
    paths = sorted(glob.glob(claude_glob))
    for path, record in read_json_lines(paths):
        message = record.get("message")
        if record.get("type") != "assistant" or not isinstance(message, dict):
            continue
        if message.get("role") != "assistant" or not isinstance(message.get("usage"), dict):
            continue
        message_id = message.get("id")
        if not isinstance(message_id, str) or not message_id:
            continue
        session_id = record.get("sessionId") or record.get("session_id") or path
        model = message.get("model") if isinstance(message.get("model"), str) else "unknown"
        final_messages[(str(session_id), message_id)] = (record_date(record), model, claude_usage(message))

    totals: dict[str, dict[str, int]] = defaultdict(empty_totals)
    for day, model, usage in final_messages.values():
        if in_range(day, since, until):
            add(totals[model], usage)
    return dict(totals)


def codex_files() -> list[str]:
    return sorted({path for pattern in CODEX_GLOBS for path in glob.glob(pattern, recursive=True)})


def codex_totals(since: str | None, until: str | None) -> dict[str, dict[str, int]]:
    """Use final cumulative counters per session; subtract a pre-range baseline."""
    sessions: dict[str, dict[str, Any]] = {}
    for path in codex_files():
        session_id = path
        model = "unknown"
        events: list[tuple[str | None, str, dict[str, int]]] = []
        for _path, record in read_json_lines([path]):
            if record.get("type") == "session_meta":
                payload = record.get("payload", {})
                if isinstance(payload, dict) and isinstance(payload.get("id"), str):
                    session_id = payload["id"]
            if record.get("type") == "turn_context":
                payload = record.get("payload", {})
                if isinstance(payload, dict) and isinstance(payload.get("model"), str):
                    model = payload["model"]
            payload = record.get("payload", {})
            if record.get("type") != "event_msg" or not isinstance(payload, dict):
                continue
            if payload.get("type") != "token_count" or not isinstance(payload.get("info"), dict):
                continue
            total = payload["info"].get("total_token_usage")
            if not isinstance(total, dict):
                continue
            # Codex's cached_input_tokens is a subset of input_tokens, so fresh
            # input is derived rather than treating cached tokens as additional.
            input_tokens = number(total.get("input_tokens"))
            cached_tokens = number(total.get("cached_input_tokens"))
            events.append((record_date(record), model, {
                "fresh_input": max(0, input_tokens - cached_tokens),
                "cache_created": 0,
                "cache_read": cached_tokens,
                "output": number(total.get("output_tokens")),
                "messages": 0,
            }))
        if not events:
            continue
        sessions.setdefault(session_id, {"events": [], "models": set()})
        sessions[session_id]["events"].extend(events)
        sessions[session_id]["models"].update(event_model for _, event_model, _ in events)

    totals: dict[str, dict[str, int]] = defaultdict(empty_totals)
    for session in sessions.values():
        events = session["events"]
        # Every event holds cumulative counters. Taking the latest counter in the
        # requested range and subtracting the last one before it avoids summing
        # the same cumulative usage for each turn.
        before = [event for event in events if event[0] is not None and since is not None and event[0] < since]
        selected = [event for event in events if in_range(event[0], since, until)]
        if not selected:
            continue
        baseline = max((event[2] for event in before), key=lambda item: sum(item[field] for field in TOKEN_FIELDS), default={field: 0 for field in TOKEN_FIELDS})
        final_day, final_model, final = max(selected, key=lambda event: sum(event[2][field] for field in TOKEN_FIELDS))
        usage = {field: max(0, final[field] - baseline[field]) for field in TOKEN_FIELDS}
        usage["messages"] = 1
        # Sessions normally have one model. If a session changed models, its final
        # cumulative total cannot be truthfully split without per-turn deltas.
        models = session["models"]
        report_model = final_model if len(models) == 1 else "mixed-session (" + ", ".join(sorted(models)) + ")"
        add(totals[report_model], usage)
    return dict(totals)


def estimated_cost(model: str, values: dict[str, int]) -> float:
    return sum(cost_components(model, values).values())


def cost_components(model: str, values: dict[str, int]) -> dict[str, float]:
    rates = PRICING.get(model, PRICING["__default__"])
    return {field: values[field] * rates.get(field, 0.0) / 1_000_000 for field in TOKEN_FIELDS}


def all_totals(groups: dict[str, dict[str, int]]) -> dict[str, int]:
    total = empty_totals()
    for values in groups.values():
        add(total, values)
    return total


def serialise_groups(groups: dict[str, dict[str, int]]) -> dict[str, dict[str, Any]]:
    return {
        model: {**values, "total_tokens": sum(values[field] for field in TOKEN_FIELDS), "estimated_cost_usd": estimated_cost(model, values)}
        for model, values in sorted(groups.items())
    }


def report_data(since: str | None, until: str | None, claude_glob: str = CLAUDE_GLOB) -> dict[str, Any]:
    claude = claude_totals(since, until, claude_glob)
    codex = codex_totals(since, until)
    claude_total = all_totals(claude)
    codex_total = all_totals(codex)
    grand = {field: claude_total[field] + codex_total[field] for field in (*TOKEN_FIELDS, "messages")}
    grand_tokens = sum(grand[field] for field in TOKEN_FIELDS)
    return {
        "filters": {"since": since, "until": until},
        "pricing_usd_per_million_tokens": PRICING,
        "claude": serialise_groups(claude),
        "codex": serialise_groups(codex),
        "grand_totals": {
            **grand,
            "total_tokens": grand_tokens,
            "claude_share_percent": (sum(claude_total[field] for field in TOKEN_FIELDS) / grand_tokens * 100) if grand_tokens else 0.0,
            "codex_share_percent": (sum(codex_total[field] for field in TOKEN_FIELDS) / grand_tokens * 100) if grand_tokens else 0.0,
        },
    }


def format_number(value: int) -> str:
    return f"{value:,}"


def markdown_table(groups: dict[str, dict[str, Any]]) -> list[str]:
    lines = ["| Model | Fresh input | Cache-created | Cache-read | Output | Messages | Total tokens |", "|---|---:|---:|---:|---:|---:|---:|"]
    if not groups:
        lines.append("| _No matching data_ | 0 | 0 | 0 | 0 | 0 | 0 |")
    for model, values in groups.items():
        lines.append("| {model} | {fresh} | {created} | {read} | {output} | {messages} | {total} |".format(
            model=model,
            fresh=format_number(values["fresh_input"]),
            created=format_number(values["cache_created"]),
            read=format_number(values["cache_read"]),
            output=format_number(values["output"]),
            messages=format_number(values["messages"]),
            total=format_number(values["total_tokens"]),
        ))
    return lines


def markdown_report(data: dict[str, Any]) -> str:
    filters = data["filters"]
    period = f"since {filters['since'] or 'the beginning'}"
    if filters["until"]:
        period += f" through {filters['until']}"
    lines = ["# Token Consumption Report", "", f"Period: {period} (inclusive)", "", "## Claude Code", ""]
    lines.extend(markdown_table(data["claude"]))
    lines.extend(["", "## Codex CLI", ""])
    lines.extend(markdown_table(data["codex"]))
    lines.extend(["", "## Combined estimated cost", "", "Placeholder rates from `PRICING`; adjust them before treating estimates as spend. Cache-read has its own rate.", "", "| Source / model | Fresh input | Cache-created | Cache-read | Output | Total (USD) |", "|---|---:|---:|---:|---:|---:|"])
    combined_rows = []
    for source in ("claude", "codex"):
        for model, values in data[source].items():
            combined_rows.append((source, model, values["estimated_cost_usd"]))
    if not combined_rows:
        lines.append("| _No matching data_ | $0.00 | $0.00 | $0.00 | $0.00 | $0.00 |")
    for source, model, cost in combined_rows:
        values = data[source][model]
        costs = cost_components(model, values)
        lines.append(
            f"| {source.title()} / {model} | ${costs['fresh_input']:,.4f} | "
            f"${costs['cache_created']:,.4f} | ${costs['cache_read']:,.4f} | "
            f"${costs['output']:,.4f} | ${cost:,.4f} |"
        )
    grand = data["grand_totals"]
    lines.extend(["", "## Grand totals", "", f"- Total tokens: {format_number(grand['total_tokens'])}", f"- Claude share: {grand['claude_share_percent']:.1f}%", f"- Codex share: {grand['codex_share_percent']:.1f}%"])
    return "\n".join(lines)


def parse_day(value: str) -> str:
    try:
        return date.fromisoformat(value).isoformat()
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", type=parse_day, help="inclusive start date (YYYY-MM-DD); default: all")
    parser.add_argument("--until", type=parse_day, help="inclusive end date (YYYY-MM-DD)")
    parser.add_argument("--json", action="store_true", help="write a machine-readable JSON report")
    parser.add_argument("--project-dir", default=os.getcwd(), help="project directory (default: current working directory)")
    args = parser.parse_args()
    if args.since and args.until and args.since > args.until:
        parser.error("--since must not be after --until")
    claude_glob = derive_claude_glob(args.project_dir)
    data = report_data(args.since, args.until, claude_glob)
    if args.json:
        json.dump(data, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(markdown_report(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
