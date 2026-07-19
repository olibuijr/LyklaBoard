#!/usr/bin/env bash
#
# LyklaBoard upstream engine sync — the codified surface behind the daily
# pi-bun scheduled task (project LYKLA).
#
# Upstream is jokull/LyklabordApp (iOS/Swift). Our fork is Kotlin/Android.
# There is NO mergeable tree: "adopt" means PORT the engine deltas 1:1 into
# AndroidClient/lib/engine (package is.solberg.lyklabord.engine), never a
# `git merge`. The iOS app/keyboard-layer commits (KeyboardExt/, App/) do not
# map onto the FlorisBoard shell and are DEFERRED, not force-ported.
#
# The git merge-base is frozen at the fork point and never advances, so it
# CANNOT be used to find "what is new since we last looked". We track an
# explicit last-adopted upstream SHA in .upstream-adopted (repo root) instead.
#
# Subcommands:
#   detect                 read-only; emit a JSON gap report (candidates only)
#   verify                 host-JVM engine tests (parity floor) + APK build + secret scan
#   mark-adopted <sha>     advance the marker to <sha> (default: upstream head)
#   ship <name> <code>     bump version, build, secret-scan, cut the GitHub release
#
# `detect` reports the git-log CANDIDATES (upstream commits touching engine
# paths since the marker). Whether a candidate is actually missing from the
# Kotlin is a content question the adopting agent reconciles — the initial port
# was taken from a checkout ahead of the merge-base, so candidates may already
# be present. The marker is advanced to the upstream head once a cycle finishes.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GRADLE_DIR="$ROOT/AndroidClient"
MARKER="$ROOT/.upstream-adopted"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
REPO="olibuijr/LyklaBoard"
ENGINE_SRC="Packages/TypeEngine/Sources/TypeEngine/"
ENGINE_TEST="Packages/TypeEngine/Tests/TypeEngineTests/"
APK="$GRADLE_DIR/app/build/outputs/apk/debug/app-debug.apk"

die() { echo "upstream-sync: $*" >&2; exit 1; }

read_marker() {
  if [[ -s "$MARKER" ]]; then
    grep -m1 -oE '[0-9a-f]{40}' "$MARKER" || die "marker $MARKER has no 40-hex SHA"
  else
    git -C "$ROOT" merge-base HEAD "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  fi
}

# class \t short-sha \t subject, one line per commit in range, oldest first.
classify() {
  local range="$1"
  git -C "$ROOT" log --reverse --format='%H%x09%h%x09%s' "$range" |
    while IFS=$'\t' read -r full short subj; do
      if git -C "$ROOT" diff-tree --no-commit-id --name-only -r "$full" |
        grep -qE "^(${ENGINE_SRC}|${ENGINE_TEST})"; then
        printf 'engine\t%s\t%s\n' "$short" "$subj"
      else
        printf 'defer\t%s\t%s\n' "$short" "$subj"
      fi
    done
}

json_of() { # <class> <report>  -> JSON array [{sha,subject}]
  awk -F'\t' -v k="$1" '$1==k{print}' <<<"$2" |
    jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))|map({sha:.[1],subject:.[2]})'
}

detect() {
  git -C "$ROOT" fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  local last head range report engine defer files
  last="$(read_marker)"
  head="$(git -C "$ROOT" rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
  range="$last..$head"
  report="$(classify "$range")"
  engine="$(json_of engine "$report")"
  defer="$(json_of defer "$report")"
  files="$(git -C "$ROOT" diff --name-only "$range" -- "$ENGINE_SRC" "$ENGINE_TEST" 2>/dev/null || true)"
  jq -n \
    --arg lastAdopted "$last" \
    --arg upstreamHead "$head" \
    --argjson engineCommits "$engine" \
    --argjson deferredCommits "$defer" \
    --arg files "$files" \
    '{
      lastAdopted: $lastAdopted,
      upstreamHead: $upstreamHead,
      engineCommits: $engineCommits,
      deferredCommits: $deferredCommits,
      engineFiles: ($files | split("\n") | map(select(length > 0))),
      hasWork: ($engineCommits | length > 0)
    }'
}

secret_scan() {
  [[ -f "$APK" ]] || die "APK not built at $APK (run verify/ship first)"
  local n
  n="$(strings -a "$APK" | grep -Ec 'sk_[A-Za-z0-9]{20,}' || true)"
  [[ "$n" == "0" ]] || die "APK contains $n ElevenLabs-shaped secret(s); refusing"
  echo "secret-scan: 0 sk_ keys in APK"
}

verify() {
  ( cd "$GRADLE_DIR"
    [[ -f local.properties ]] || echo "sdk.dir=/home/olafurbui/Projects/pi-bun/android/.sdk" >local.properties
    ./gradlew :lib:engine:test --no-daemon --console=plain
    ./gradlew :app:assembleDebug --no-daemon --console=plain )
  secret_scan
  echo "verify: OK (engine tests incl. parity floor, assembleDebug, secret scan)"
}

mark_adopted() {
  local sha="${1:-}"
  [[ -n "$sha" ]] || sha="$(git -C "$ROOT" rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
  sha="$(git -C "$ROOT" rev-parse "$sha")"
  printf '%s\n' "$sha" >"$MARKER"
  echo "marker -> $sha"
}

ship() { # <versionName> <versionCode>
  local vn="${1:?ship needs <versionName>}" vc="${2:?ship needs <versionCode>}"
  sed -i "s/^projectVersionName=.*/projectVersionName=$vn/" "$GRADLE_DIR/gradle.properties"
  sed -i "s/^projectVersionCode=.*/projectVersionCode=$vc/" "$GRADLE_DIR/gradle.properties"
  verify
  gh release create "v$vn" "$APK" -R "$REPO" --title "v$vn" --generate-notes
  echo "shipped v$vn ($vc)"
}

case "${1:-}" in
  detect) detect ;;
  verify) verify ;;
  mark-adopted) shift; mark_adopted "${1:-}" ;;
  ship) shift; ship "${1:-}" "${2:-}" ;;
  *) die "usage: upstream-sync.sh {detect|verify|mark-adopted <sha>|ship <name> <code>}" ;;
esac
