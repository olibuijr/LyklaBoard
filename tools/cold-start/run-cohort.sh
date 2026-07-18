#!/usr/bin/env bash
# Collect a verified process-cold keyboard-extension cohort on one device.
set -euo pipefail

DEVICE="${1:-}"
RUN_COUNT="${2:-20}"
GROUP_ID="group.is.solberg.lyklabord"
HOST_BUNDLE_ID="is.solberg.lyklabord"
HOST_EXECUTABLE="Lyklabord"
EXTENSION_EXECUTABLE="LyklabordKeyboard"
SOURCE="Documents/diagnostics/cold-start.jsonl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="${SCRIPT_DIR}/runs"

if [[ -z "${DEVICE}" ]] || ! [[ "${RUN_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: tools/cold-start/run-cohort.sh <device-id> [positive-run-count]" >&2
  exit 64
fi

TMP_DIR="$(mktemp -d /tmp/lyklabord-cold-cohort.XXXXXX)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT
mkdir -p "${RUNS_DIR}"

process_json() {
  local destination="$1"
  xcrun devicectl device info processes \
    --device "${DEVICE}" \
    --json-output "${destination}" \
    --quiet
}

pids_for_executable() {
  local source_json="$1"
  local executable="$2"
  jq -r --arg suffix "/${executable}" '
    .result.runningProcesses[]
    | select(.executable | endswith($suffix))
    | .processIdentifier
  ' "${source_json}"
}

terminate_executable() {
  local executable="$1"
  local listing="${TMP_DIR}/processes-${executable}.json"
  process_json "${listing}"
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    xcrun devicectl device process terminate \
      --device "${DEVICE}" \
      --pid "${pid}" \
      --kill \
      --quiet
  done < <(pids_for_executable "${listing}" "${executable}")
}

stop_extension_at_launch_boundary() {
  local attempt listing
  for ((attempt = 1; attempt <= 8; attempt++)); do
    terminate_executable "${EXTENSION_EXECUTABLE}"
    sleep 0.25
    listing="${TMP_DIR}/processes-stopped-${attempt}.json"
    process_json "${listing}"
    if [[ -z "$(pids_for_executable "${listing}" "${EXTENSION_EXECUTABLE}")" ]]; then
      return
    fi
  done
  echo "Extension kept relaunching before the probe; refusing a warm sample." >&2
  exit 70
}

pull_journal() {
  local destination="$1"
  xcrun devicectl device copy from \
    --device "${DEVICE}" \
    --domain-type appGroupDataContainer \
    --domain-identifier "${GROUP_ID}" \
    --source "${SOURCE}" \
    --destination "${destination}" \
    --quiet
}

validate_journal() {
  local journal="$1"
  local expected_count="$2"
  python3 - "${journal}" "${expected_count}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected = int(sys.argv[2])
records = []
for line_number, line in enumerate(path.read_text().splitlines(), 1):
    if not line.strip():
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}")
    if record.get("schema") != "lyklabord.cold-start.v1":
        raise SystemExit(f"{path}:{line_number}: unexpected schema")
    if record.get("isSimulator") is not False:
        raise SystemExit(f"{path}:{line_number}: simulator sample in physical cohort")
    if record.get("isProcessCold") is not True:
        raise SystemExit(f"{path}:{line_number}: warm presentation in cold cohort")
    records.append(record)

run_ids = {record.get("runId") for record in records}
if len(records) != expected:
    raise SystemExit(f"expected {expected} records, found {len(records)}")
if len(run_ids) != len(records) or None in run_ids:
    raise SystemExit("missing or duplicate runId in cohort")
PY
}

BASELINE="${TMP_DIR}/baseline.jsonl"
pull_journal "${BASELINE}"
BASELINE_COUNT="$(awk 'NF { count++ } END { print count + 0 }' "${BASELINE}")"
if ! validate_journal "${BASELINE}" "${BASELINE_COUNT}"; then
  echo "Existing device journal is not a valid resumable cold cohort." >&2
  echo "Archive and clear it before starting a new cohort:" >&2
  echo "  tools/cold-start/pull.sh ${DEVICE}" >&2
  exit 65
fi
if ((BASELINE_COUNT > RUN_COUNT)); then
  echo "Device already has ${BASELINE_COUNT} valid runs, more than requested ${RUN_COUNT}." >&2
  exit 65
fi

echo "Collecting ${RUN_COUNT} process-cold runs (${BASELINE_COUNT} already verified). Keep the iPhone unlocked."
COMPLETE="${BASELINE}"
for ((run = BASELINE_COUNT + 1; run <= RUN_COUNT; run++)); do
  # Dismiss the focused host first so iOS cannot immediately respawn its
  # keyboard extension, then kill the extension and prove it stayed gone.
  terminate_executable "${HOST_EXECUTABLE}"
  sleep 1
  stop_extension_at_launch_boundary

  LAUNCH_LOG="${TMP_DIR}/launch-${run}.log"
  if ! xcrun devicectl device process launch \
    --device "${DEVICE}" \
    --environment-variables '{"LYKLABORD_COLD_START_PROBE":"1"}' \
    --terminate-existing \
    "${HOST_BUNDLE_ID}" >"${LAUNCH_LOG}" 2>&1
  then
    if grep -q 'because the device was not, or could not be, unlocked' "${LAUNCH_LOG}"; then
      echo "Run ${run}: iPhone is locked. Unlock it and rerun the cohort." >&2
      exit 66
    fi
    sed -n '1,120p' "${LAUNCH_LOG}" >&2
    exit 67
  fi

  COMPLETE=""
  for ((attempt = 1; attempt <= 10; attempt++)); do
    sleep 1
    CANDIDATE="${TMP_DIR}/journal-${run}-${attempt}.jsonl"
    pull_journal "${CANDIDATE}"
    if validate_journal "${CANDIDATE}" "${run}" 2>/dev/null; then
      COMPLETE="${CANDIDATE}"
      break
    fi
  done
  if [[ -z "${COMPLETE}" ]]; then
    echo "Run ${run}: no new valid cold sample after 10 seconds." >&2
    echo "Confirm Lyklaborð is the selected keyboard and Full Access is enabled." >&2
    exit 68
  fi
  printf '  %d/%d verified\n' "${run}" "${RUN_COUNT}"
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DESTINATION="${RUNS_DIR}/cold-start-cohort-${STAMP}.jsonl"
cp "${COMPLETE}" "${DESTINATION}"
echo "Saved ${DESTINATION}"
python3 "${SCRIPT_DIR}/report.py" --gate "${DESTINATION}"
