#!/usr/bin/env python3
"""
ingest.py — collect DEV-MODE typing sessions from every source into the
canonical `sessions/` dir, analyze new arrivals, and refresh the aggregate.

Sources scanned (each optional; a missing dir is skipped, never fatal):

  1. the iCloud Drive mirror on THIS Mac — the OTA path. When developer mode
     copies a session into the app's ubiquity container, iCloud syncs it to
     ~/Library/Mobile Documents/<container>/Documents/sessions on the Mac.

       Container id:      iCloud.is.lyklabord
       Mobile-Documents:  iCloud~is~lyklabord   (dots → tildes, no team prefix,
                          no ".ios" suffix — the app's ubiquity container is
                          `iCloud.is.lyklabord`, NOT `iCloud.is.lyklabord.ios`)

     Full default path:
       ~/Library/Mobile Documents/iCloud~is~lyklabord/Documents/sessions

     Override with --ubiquity-dir (or LYKLABORD_UBIQUITY_DIR) if your account
     encodes it differently.

  2. a devicectl USB-pull staging dir (pull.sh). By default this IS the
     canonical sessions/ dir (pull.sh copies straight into it), so nothing is
     duplicated; pass --pull-dir to stage elsewhere first.

Dedupe is by SESSION ID: a file is copied into `sessions/` only when it is
absent there or the source copy is larger (sessions are append-only, so a
larger file is a superset). Only sessions whose files actually changed are
re-analyzed; then aggregate.py rebuilds AGGREGATE.md / aggregate.json /
personal-eval.jsonl.

Stdlib only.

    python3 ingest.py                       # one pass, default sources
    python3 ingest.py --watch               # poll every 15s
    python3 ingest.py --ubiquity-dir DIR --pull-dir DIR --sessions-dir DIR
"""

import argparse
import os
import shutil
import sys
import time

import analyze
import aggregate

DEFAULT_UBIQUITY = os.path.expanduser(
    "~/Library/Mobile Documents/iCloud~is~lyklabord/Documents/sessions")

SESSION_SUFFIXES = ("-app.jsonl", "-kb.jsonl", "-meta.json")


def _session_id(filename: str):
    for suf in SESSION_SUFFIXES:
        if filename.endswith(suf):
            return filename[: -len(suf)]
    return None


def _size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return -1


def sync_source(src_dir: str, dest_dir: str) -> set:
    """Copy session files from `src_dir` into `dest_dir` when new/larger.
    Returns the set of session ids that changed."""
    changed = set()
    if not src_dir or not os.path.isdir(src_dir):
        return changed
    if os.path.abspath(src_dir) == os.path.abspath(dest_dir):
        return changed  # canonical dir is its own source — nothing to copy
    for name in os.listdir(src_dir):
        sid = _session_id(name)
        if sid is None:
            continue
        src = os.path.join(src_dir, name)
        dst = os.path.join(dest_dir, name)
        if not os.path.isfile(src):
            continue
        if _size(dst) >= _size(src) and os.path.exists(dst):
            continue  # already have an equal-or-larger copy
        shutil.copy2(src, dst)
        changed.add(sid)
    return changed


def ingest_once(sessions_dir: str, sources: list, verbose: bool = True) -> dict:
    os.makedirs(sessions_dir, exist_ok=True)
    repo_root = analyze._repo_root()

    changed = set()
    for src in sources:
        changed |= sync_source(src, sessions_dir)

    # Also analyze any session already present but never analyzed (no report).
    for sid in analyze.discover_sessions(sessions_dir):
        report = os.path.join(sessions_dir, f"{sid}-report.md")
        if not os.path.exists(report):
            changed.add(sid)

    for sid in sorted(changed):
        s = analyze.analyze_one(sessions_dir, sid, repo_root)
        if verbose:
            print(f"  analyzed {sid}: {s['events']} events, "
                  f"{s['silent_miss']} silent-miss ({s['silent_source']})")

    summary = aggregate.build(sessions_dir)
    if verbose:
        o = summary["overall"]
        print(f"  aggregate: {o['sessions']} sessions / "
              f"{len(summary['by_build'])} builds, corpus "
              f"{summary['personal_eval']['total']} rows "
              f"(+{len(summary['personal_eval']['added'])}), "
              f"{len(summary['personal_eval']['pending'])} pending")
    return {"changed": sorted(changed), "summary": summary}


def main(argv: list) -> int:
    default_sessions = os.path.join(os.path.dirname(__file__), "sessions")
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sessions-dir", default=default_sessions,
                    help="canonical dir (default: ./sessions)")
    ap.add_argument("--ubiquity-dir",
                    default=os.environ.get("LYKLABORD_UBIQUITY_DIR", DEFAULT_UBIQUITY),
                    help="iCloud Drive mirror of the app's ubiquity container")
    ap.add_argument("--pull-dir", default=None,
                    help="devicectl USB-pull staging dir (default: none — pull.sh "
                         "already lands in --sessions-dir)")
    ap.add_argument("--watch", action="store_true", help="poll continuously")
    ap.add_argument("--interval", type=float, default=15.0,
                    help="watch poll interval seconds (default: 15)")
    args = ap.parse_args(argv[1:])

    sources = [args.ubiquity_dir]
    if args.pull_dir:
        sources.append(args.pull_dir)

    def run():
        present = [s for s in sources if os.path.isdir(s)]
        missing = [s for s in sources if not os.path.isdir(s)]
        print(f"[ingest] sources: {present or '(none present)'}"
              + (f"  · absent: {missing}" if missing else ""))
        ingest_once(args.sessions_dir, sources)

    if args.watch:
        print(f"[ingest] watch mode, every {args.interval}s. Ctrl-C to stop.")
        try:
            while True:
                run()
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\n[ingest] stopped.")
            return 0
    else:
        run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
