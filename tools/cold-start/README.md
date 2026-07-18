# Cold-first-usable measurement

Wave 39 measures a real keyboard-extension process from the entry to
`KeyboardViewController.viewDidLoad` through service creation, engine readiness,
and the first publishable, non-empty result. It also measures the request
backlog that formed behind bootstrap. No typed text, key values, suggestions,
or user identifiers are recorded.

The extension appends a bounded local journal at
`Documents/diagnostics/cold-start.jsonl` in the App Group. Each record marks
whether it came from the first service created in that extension process;
`report.py` excludes later presentations and Simulator samples by default so a
warm retry cannot hide the cold number. It deduplicates `runId` values because
each pull copies the cumulative journal, rejects incomplete records, and fails
a full gate if device model, OS, extension version, or extension build are
mixed.

```sh
tools/cold-start/run-cohort.sh <device-id> 20
tools/cold-start/pull.sh <device-id>
python3 tools/cold-start/report.py tools/cold-start/runs
python3 tools/cold-start/report.py --gate tools/cold-start/runs
swiftc KeyboardExt/ColdStartMetrics.swift tools/cold-start/tracker_tests.swift \
  -o /tmp/lyklabord-cold-start-tracker-tests && \
  /tmp/lyklabord-cold-start-tracker-tests
```

The hard gate requires 20 process-cold physical-device launches. Budgets live
in `budget.json`. `activationToEngineReadyMs` includes controller and App Group
setup before the service exists; `activationToServiceCreationMs` makes that
portion visible. `activationToStableResultMs` and `serviceToStableResultMs` are
observational UX numbers because they contain the user's delay before typing;
the gated `firstRequestToStableResultMs` starts when the first KeyboardKit
request arrives. A stable result is non-empty and not superseded at
publication.

The first accepted physical baseline is committed as
`baselines/wave-39-iphone14pro-ios26.5.2-build4.json`. It is an aggregate only;
the cumulative raw journals remain ignored under `runs/`. Compare like with
like: the reporter deliberately rejects a gated cohort that mixes device model,
OS, extension version, or extension build.

Wave 40's generation-bound calibration-sidecar cohort is committed separately
as `baselines/wave-40-calibration-iphone14pro-ios26.5.2-build4.json`. It uses
the same device/OS/marketing build as Wave 39 but a later dirty source build;
the filename records the implementation boundary that the marketing build
cannot distinguish. Its raw 20-run journal remains ignored like every cohort.

For a true process-cold run, dismiss the keyboard and ensure the extension
process has ended before presenting it again. Merely reopening the keyboard
inside a surviving extension process produces `isProcessCold: false` and is
excluded. Use a Release build on a physical device; the Simulator path is for
instrumentation smoke tests only.

`run-cohort.sh` automates that hygiene for the deterministic host bundled in
Release builds. It requires either an empty journal or a valid partial cold
cohort, so an interrupted run resumes without double-counting. It terminates
the containing app first, repeatedly terminates/rechecks the extension until
iOS proves it absent at the launch boundary, launches the host with its
cold-probe environment flag, and accepts each iteration only after the journal
contains exactly one new, unique, physical `isProcessCold` record. Keep the
phone unlocked and Lyklaborð selected while it runs. A locked phone or
missing/warm sample aborts the cohort instead of silently lowering the measured
latency.

Collect one cohort from one installed Release build without reinstalling it
mid-run. Clear or archive the device journal before starting a new build's
cohort; version/build consistency is enforced, but locally rebuilt binaries can
share the same marketing build number.
