#!/usr/bin/env python3
"""Summarize and gate local Wave-39 keyboard cold-start samples."""

import argparse
import json
import math
import sys
from pathlib import Path


SCHEMA = "lyklabord.cold-start.v1"
PERCENTILES = ("p50", "p95", "p99")
METRICS = (
    "activationToEngineReadyMs",
    "firstRequestToStableResultMs",
    "backlogDrainMs",
)
OBSERVATIONAL_METRICS = (
    "activationToServiceCreationMs",
    "activationToStableResultMs",
    "serviceToEngineReadyMs",
    "serviceToStableResultMs",
    "serviceToFirstRequestMs",
    "bootstrapDurationMs",
)
ALL_METRICS = METRICS + OBSERVATIONAL_METRICS
COUNT_METRICS = (
    "engineReadyBacklogDepth",
    "maxQueuedWindowDepth",
    "requestsAcceptedBeforeReady",
    "requestsCompletedBeforeStable",
    "outdatedResultsBeforeStable",
)
COHORT_FIELDS = (
    "deviceModel",
    "osVersion",
    "extensionVersion",
    "extensionBuild",
)


def percentile(values: list[float], probability: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    rank = probability * (len(ordered) - 1)
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    fraction = rank - low
    return ordered[low] * (1 - fraction) + ordered[high] * fraction


def _valid_sample(item: object) -> bool:
    if not isinstance(item, dict) or item.get("schema") != SCHEMA:
        return False
    if not isinstance(item.get("runId"), str) or not item["runId"]:
        return False
    if not isinstance(item.get("isProcessCold"), bool):
        return False
    if not isinstance(item.get("isSimulator"), bool):
        return False
    if any(not isinstance(item.get(field), str) or not item[field]
           for field in COHORT_FIELDS):
        return False
    metrics = item.get("metrics")
    if not isinstance(metrics, dict):
        return False
    for name in ALL_METRICS:
        value = metrics.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return False
        if not math.isfinite(float(value)) or float(value) < 0:
            return False
    for name in COUNT_METRICS:
        value = metrics.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return False
    return True


def load_samples(paths: list[str]) -> tuple[list[dict], int, int]:
    samples: list[dict] = []
    rejected = 0
    duplicates = 0
    seen_run_ids: set[str] = set()
    for raw_path in paths:
        path = Path(raw_path)
        candidates = sorted(path.glob("*.jsonl")) if path.is_dir() else [path]
        for candidate in candidates:
            if not candidate.exists():
                continue
            with candidate.open(encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    # Also accept Console exports containing COLD_START_JSON.
                    marker = "COLD_START_JSON "
                    if marker in line:
                        line = line.split(marker, 1)[1]
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        rejected += 1
                        continue
                    if not _valid_sample(item):
                        rejected += 1
                        continue
                    if item["runId"] in seen_run_ids:
                        duplicates += 1
                        continue
                    seen_run_ids.add(item["runId"])
                    samples.append(item)
    return samples, rejected, duplicates


def summarize(samples: list[dict], budget: dict, include_simulator: bool = False,
              include_warm_presentations: bool = False) -> dict:
    selected = [
        sample for sample in samples
        if (include_simulator or not sample.get("isSimulator", False))
        and (include_warm_presentations or sample.get("isProcessCold", False))
    ]
    summary = {
        "schema": "lyklabord.cold-start-report.v1",
        "sampleCount": len(selected),
        "totalInputSamples": len(samples),
        "filters": {
            "physicalDeviceOnly": not include_simulator,
            "processColdOnly": not include_warm_presentations,
        },
        "budget": budget,
        "cohort": {},
        "cohortConsistent": False,
        "metrics": {},
        "maxQueuedWindowDepth": None,
        "gate": {"status": "insufficient-data", "failures": []},
    }
    if not selected:
        return summary

    summary["cohort"] = {
        field: sorted({str(sample[field]) for sample in selected})
        for field in COHORT_FIELDS
    }
    summary["cohortConsistent"] = all(
        len(values) == 1 for values in summary["cohort"].values())

    for name in ALL_METRICS:
        values = [float(sample["metrics"][name]) for sample in selected]
        summary["metrics"][name] = {
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
            "p99": percentile(values, 0.99),
            "max": max(values),
        }
    summary["maxQueuedWindowDepth"] = max(
        int(sample["metrics"]["maxQueuedWindowDepth"]) for sample in selected)

    minimum = int(budget["minimumColdRuns"])
    if len(selected) < minimum:
        summary["gate"]["failures"].append(
            f"need {minimum} process-cold physical-device runs; found {len(selected)}")
        return summary

    failures = []
    if not summary["cohortConsistent"]:
        mixed = [field for field, values in summary["cohort"].items() if len(values) != 1]
        failures.append("mixed measurement cohort: " + ", ".join(mixed))
    for metric in METRICS:
        for label in PERCENTILES:
            observed = summary["metrics"][metric][label]
            limit = float(budget[metric][label])
            if observed > limit:
                failures.append(
                    f"{metric}.{label} {observed:.1f} ms exceeds {limit:.1f} ms")
    depth = summary["maxQueuedWindowDepth"]
    depth_limit = int(budget["maxQueuedWindowDepth"])
    if depth > depth_limit:
        failures.append(f"maxQueuedWindowDepth {depth} exceeds {depth_limit}")
    summary["gate"] = {"status": "fail" if failures else "pass", "failures": failures}
    return summary


def render(summary: dict, rejected: int, duplicates: int) -> str:
    lines = [
        "Wave 39 cold-first-usable report",
        f"  selected runs       {summary['sampleCount']} / {summary['totalInputSamples']}",
        f"  rejected lines      {rejected}",
        f"  duplicate run ids   {duplicates}",
    ]
    for field, values in summary["cohort"].items():
        lines.append(f"  {field:<20} {', '.join(values)}")
    for name in ALL_METRICS:
        stats = summary["metrics"].get(name)
        if not stats:
            continue
        lines.append(
            f"  {name:<33} p50 {stats['p50']:7.1f}  p95 {stats['p95']:7.1f}  "
            f"p99 {stats['p99']:7.1f}  max {stats['max']:7.1f} ms")
    if summary["maxQueuedWindowDepth"] is not None:
        lines.append(f"  max queued-window depth            {summary['maxQueuedWindowDepth']}")
    lines.append(f"  gate                {summary['gate']['status']}")
    lines.extend(f"    - {failure}" for failure in summary["gate"]["failures"])
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="cold-start JSONL file(s) or directories")
    parser.add_argument("--budget", default=str(here / "budget.json"))
    parser.add_argument("--json-out")
    parser.add_argument("--include-simulator", action="store_true")
    parser.add_argument("--include-warm-presentations", action="store_true")
    parser.add_argument("--gate", action="store_true",
                        help="exit non-zero on insufficient data or a failed budget")
    args = parser.parse_args(argv[1:])

    with open(args.budget, encoding="utf-8") as handle:
        budget = json.load(handle)
    samples, rejected, duplicates = load_samples(args.paths)
    summary = summarize(samples, budget, args.include_simulator,
                        args.include_warm_presentations)
    print(render(summary, rejected, duplicates))
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)
            handle.write("\n")
    if args.gate:
        return 0 if summary["gate"]["status"] == "pass" else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
