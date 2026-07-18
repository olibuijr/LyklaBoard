#!/usr/bin/env python3
import json
import itertools
import tempfile
import unittest
from pathlib import Path

import report


RUN_IDS = itertools.count(1)


def sample(value: float, *, cold: bool = True, simulator: bool = False,
           depth: int = 2, run_id: str | None = None,
           device: str = "iPhone15,2") -> dict:
    return {
        "schema": report.SCHEMA,
        "runId": run_id or f"run-{next(RUN_IDS)}",
        "deviceModel": device,
        "osVersion": "Version 26.5.2",
        "extensionVersion": "1.0",
        "extensionBuild": "4",
        "isProcessCold": cold,
        "isSimulator": simulator,
        "metrics": {
            "bootstrapDurationMs": value,
            "activationToServiceCreationMs": value / 4,
            "activationToEngineReadyMs": value,
            "activationToStableResultMs": value * 1.75,
            "serviceToEngineReadyMs": value,
            "serviceToFirstRequestMs": value / 2,
            "firstRequestToStableResultMs": value,
            "serviceToStableResultMs": value * 1.5,
            "backlogDrainMs": value / 2,
            "engineReadyBacklogDepth": depth,
            "maxQueuedWindowDepth": depth,
            "requestsAcceptedBeforeReady": depth,
            "requestsCompletedBeforeStable": depth,
            "outdatedResultsBeforeStable": max(depth - 1, 0),
        },
    }


class ColdStartReportTests(unittest.TestCase):
    def setUp(self):
        self.budget = {
            "minimumColdRuns": 3,
            "activationToEngineReadyMs": {"p50": 20, "p95": 30, "p99": 30},
            "firstRequestToStableResultMs": {"p50": 20, "p95": 30, "p99": 30},
            "backlogDrainMs": {"p50": 10, "p95": 15, "p99": 15},
            "maxQueuedWindowDepth": 4,
        }

    def test_percentile_interpolates(self):
        self.assertEqual(report.percentile([0, 10, 20], 0.50), 10)
        self.assertAlmostEqual(report.percentile([0, 10], 0.95), 9.5)

    def test_default_filter_and_pass(self):
        result = report.summarize(
            [sample(10), sample(20), sample(30), sample(99, cold=False),
             sample(99, simulator=True)], self.budget)
        self.assertEqual(result["sampleCount"], 3)
        self.assertEqual(result["gate"]["status"], "pass")

    def test_insufficient_and_failure_are_distinct(self):
        insufficient = report.summarize([sample(10)], self.budget)
        self.assertEqual(insufficient["gate"]["status"], "insufficient-data")
        failed = report.summarize(
            [sample(40, depth=5), sample(40), sample(40)], self.budget)
        self.assertEqual(failed["gate"]["status"], "fail")
        self.assertTrue(any("maxQueuedWindowDepth" in item
                            for item in failed["gate"]["failures"]))

    def test_loader_accepts_journal_and_console_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cold.jsonl"
            path.write_text(
                json.dumps(sample(10)) + "\n"
                + "noise COLD_START_JSON " + json.dumps(sample(20)) + "\n"
                + "not-json\n", encoding="utf-8")
            samples, rejected, duplicates = report.load_samples([str(path)])
        self.assertEqual(len(samples), 2)
        self.assertEqual(rejected, 1)
        self.assertEqual(duplicates, 0)

    def test_loader_deduplicates_cumulative_journal_pulls(self):
        duplicate = sample(10, run_id="same-run")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "first.jsonl").write_text(
                json.dumps(duplicate) + "\n", encoding="utf-8")
            (root / "second.jsonl").write_text(
                json.dumps(duplicate) + "\n", encoding="utf-8")
            samples, rejected, duplicates = report.load_samples([str(root)])
        self.assertEqual(len(samples), 1)
        self.assertEqual(rejected, 0)
        self.assertEqual(duplicates, 1)

    def test_malformed_sample_is_rejected(self):
        malformed = sample(10)
        del malformed["metrics"]["backlogDrainMs"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.jsonl"
            path.write_text(json.dumps(malformed) + "\n", encoding="utf-8")
            samples, rejected, duplicates = report.load_samples([str(path)])
        self.assertEqual(samples, [])
        self.assertEqual(rejected, 1)
        self.assertEqual(duplicates, 0)

    def test_mixed_device_cohort_fails_gate(self):
        result = report.summarize(
            [sample(10), sample(10), sample(10, device="iPhone16,1")],
            self.budget,
        )
        self.assertEqual(result["gate"]["status"], "fail")
        self.assertTrue(any("mixed measurement cohort" in failure
                            for failure in result["gate"]["failures"]))


if __name__ == "__main__":
    unittest.main()
