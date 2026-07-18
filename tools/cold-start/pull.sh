#!/usr/bin/env bash
# Pull the privacy-safe Wave-39 journal from a connected device's App Group.
set -euo pipefail

GROUP_ID="group.is.solberg.lyklabord"
SOURCE="Documents/diagnostics/cold-start.jsonl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${SCRIPT_DIR}/runs"
DEVICE="${1:-}"

if [[ -z "${DEVICE}" ]]; then
  echo "Usage: tools/cold-start/pull.sh <device-id>" >&2
  echo "Get the exact id from 'xcrun devicectl list devices'." >&2
  exit 1
fi

mkdir -p "${DEST_DIR}"
DEST="${DEST_DIR}/cold-start-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
xcrun devicectl device copy from \
  --device "${DEVICE}" \
  --domain-type appGroupDataContainer \
  --domain-identifier "${GROUP_ID}" \
  --source "${SOURCE}" \
  --destination "${DEST}"

echo "Pulled ${DEST}"
python3 "${SCRIPT_DIR}/report.py" "${DEST}"
