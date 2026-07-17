#!/usr/bin/env python3
"""Generate data/eval/compounds.jsonl from the Miðeind/iceErrorCorpus
compound-case harvest (wave 31 — see docs/WAVES.md and
research/mideind-compound-cases.md).

Input:  research/mideind-compound-cases.jsonl (2,052 curated rows)
Output: data/eval/compounds.jsonl — CorpusPair-shaped rows replayable by
        `type-eval corpus compounds` (same schema as dev.jsonl/heldout.jsonl)

Selection discipline (the wave-31 rules, in order):

 1. Shape transform. The corpus rows come in three replayable shapes:
      * single-token typo -> single-token intended (compound-collocation,
        joined missing-hyphen): replayed as-is (typo = currentWord).
      * single-token typo -> two-word intended (C002 wrongly-joined):
        replayed as-is — the space-miss split machinery CAN reach these.
      * two-token typo "A B" -> joined/hyphenated intended (split-compound,
        split-word, split-words, C003, spaced missing-hyphen): replayed as
        context=[A], typo=B, intended=<corpus intended>. The engine has no
        cross-token join machinery, so top-1 is structurally 0 today —
        these rows TRACK the gap, and because B is required to be a valid
        word (filter 3) any autocorrect fire on them is a false-ac: they
        double as protection assertions.
 2. Shape purity. Alignment noise in the TEI-derived corpus leaves rows
    whose "correction" also changes inflection, casing beyond the join, or
    carries its own typo ("Westminsterhöll" -> "Westminister-höll"). The
    join-shaped categories are therefore required to be EXACT joins:
      * missing_hyphen:        intended minus its hyphens == typo (case-
        insensitively) — a pure hyphen insertion, nothing else.
      * missing_hyphen_spaced: intended == "A-B" for the typed "A B".
      * wrongly_split:         intended == "AB" for the typed "A B".
    compound_collocation rows are exempt (a linking-letter change IS the
    error), only length drift keeps them honest (harvest-side filter).
 3. Dedupe on (typo, intended, category, context).
 4. Validity filter (doctrine: a valid word is never auto-replaced, so a
    valid "typo" cannot be a corrector target):
      * corrector-target categories (compound_collocation, missing_hyphen,
        wrongly_joined-with-invalid-typo): typo must NOT be engine-valid.
        Compound-PROTECTED-but-invalid typos are kept — they are exactly
        the linking-letter-yield class.
      * wrongly_joined rows with a VALID typo are kept too: they measure
        the deny-list split OFFER (bar top-1), never an auto-apply.
      * protection-assertion categories (wrongly_split,
        missing_hyphen_spaced): the replayed token B MUST be engine-valid.
    Validity is probed through the real artifacts via `type-repl`'s
    `:compound` command (one batch process).
 5. Stratified cap per category (below), selected by md5(typo|intended)
    order — deterministic and alphabet-unbiased.

Licensing: 2,004 source rows are iceErrorCorpus (CC BY 4.0 — see
data/ATTRIBUTION.md "Icelandic Error Corpus"); 16 are GreynirCorrect test
assertions (MIT). Every emitted row keeps a `source` field.

Usage (from repo root; builds/locates type-repl itself):
    python3 data/eval/generate-compounds-eval.py
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HARVEST = REPO / "research" / "mideind-compound-cases.jsonl"
OUT = REPO / "data" / "eval" / "compounds.jsonl"
PACKAGE = REPO / "Packages" / "TypeEngine"

# category -> cap (md5-ordered head after filters). Total target ~700.
CAPS = {
    "compound_collocation": 250,
    "wrongly_joined": 16,
    "missing_hyphen": 150,
    "missing_hyphen_spaced": 100,
    "wrongly_split": 200,
}


def repl_binary() -> Path:
    subprocess.run(
        ["swift", "build", "-c", "release", "--product", "type-repl"],
        cwd=PACKAGE, check=True, capture_output=True)
    bin_dir = subprocess.run(
        ["swift", "build", "-c", "release", "--show-bin-path"],
        cwd=PACKAGE, check=True, capture_output=True, text=True).stdout.strip()
    return Path(bin_dir) / "type-repl"


def probe_validity(words):
    """word -> (valid, protected) via one batched type-repl session."""
    words = sorted(set(words))
    script = "".join(f":compound {w}\n" for w in words) + ":q\n"
    out = subprocess.run(
        [str(repl_binary())], input=script, cwd=REPO,
        capture_output=True, text=True).stdout
    results = [l for l in out.splitlines() if "valid=" in l]
    if len(results) != len(words):
        sys.exit(f"probe mismatch: {len(words)} words, {len(results)} results")
    verdict = {}
    for word, line in zip(words, results):
        verdict[word] = ("valid=true" in line, "protected=true" in line)
    return verdict


def clean_token(t: str) -> bool:
    return bool(t) and all(c.isalpha() or c == "-" for c in t)


def main():
    rows = [json.loads(l) for l in HARVEST.open()]
    errors = [r for r in rows if r["cls"] == "compound_error"]

    candidates = []  # (category, typo, intended, context, source)
    for r in errors:
        typo, intended, code = r["typo"], r["intended"], r["error_code"]
        source = r["source_repo"]
        if code == "compound-collocation":
            if " " in typo or " " in intended:
                continue  # alignment-noise rows (preposition swaps etc.)
            if not (clean_token(typo) and clean_token(intended)):
                continue
            candidates.append(("compound_collocation", typo, intended, [], source))
        elif code == "C002":
            candidates.append(("wrongly_joined", typo, intended, [], source))
        elif code == "missing-hyphen":
            if " " not in typo and " " not in intended and clean_token(typo) \
                    and clean_token(intended):
                if intended.replace("-", "").lower() != typo.lower():
                    continue  # shape purity: exact hyphen insertion only
                candidates.append(("missing_hyphen", typo, intended, [], source))
            elif typo.count(" ") == 1 and " " not in intended:
                first, second = typo.split(" ")
                if clean_token(first) and clean_token(second) and clean_token(intended) \
                        and intended.lower() == f"{first}-{second}".lower():
                    candidates.append(
                        ("missing_hyphen_spaced", second, intended, [first], source))
        elif code in ("split-compound", "split-word", "split-words", "C003"):
            if " " in intended or not clean_token(intended):
                continue
            parts = typo.split(" ")
            if len(parts) != 2 or not all(clean_token(p) for p in parts):
                continue
            if intended.lower() != (parts[0] + parts[1]).lower():
                continue  # shape purity: exact join only
            candidates.append(("wrongly_split", parts[1], intended, [parts[0]], source))

    # Dedupe (case-insensitive key so "Aðal inngangur"/"aðal inngangur"
    # collapse).
    seen = set()
    deduped = []
    for c in candidates:
        key = (c[0], c[1].lower(), c[2].lower(), tuple(w.lower() for w in c[3]))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(c)

    verdict = probe_validity({c[1].lower() for c in deduped})

    kept = {name: [] for name in CAPS}
    for category, typo, intended, context, source in deduped:
        valid, _protected = verdict[typo.lower()]
        if category in ("compound_collocation", "missing_hyphen"):
            if valid:
                continue  # doctrine: valid words are never corrector targets
        elif category in ("wrongly_split", "missing_hyphen_spaced"):
            if not valid:
                continue  # protection assertions need a protected token
        kept[category].append((category, typo, intended, context, source))

    with OUT.open("w") as f:
        total = 0
        for category in sorted(kept):
            rows_ = sorted(
                kept[category],
                key=lambda c: hashlib.md5(
                    f"{c[1]}|{c[2]}".encode()).hexdigest())[: CAPS[category]]
            rows_.sort(key=lambda c: (c[1].lower(), c[2].lower()))
            for _, typo, intended, context, source in rows_:
                f.write(json.dumps({
                    "typo": typo, "intended": intended, "context": context,
                    "lang": "is", "category": category, "source": source,
                }, ensure_ascii=False) + "\n")
            print(f"{category}: {len(rows_)} (of {len(kept[category])} eligible)")
            total += len(rows_)
        print(f"total: {total} -> {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
