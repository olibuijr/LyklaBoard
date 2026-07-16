# Lyklaborð — Data Export Format

_Format version 1. This document is referenced by the `$schema` field of
every export file._

The "Flytja út gögnin mín" (Export my data) action writes a single UTF-8
JSON file containing everything the keyboard has learned on your device. It
is human-readable by design — you can open it in any text editor and read
exactly what the keyboard knows about you. This is the symmetric counterpart
to the SwiftKey import: your data is yours to take with you.

The file is a snapshot. It is not synced, not uploaded, and (in this version)
not re-importable — its purpose is portability and transparency.

## Envelope

| Field | Type | Meaning |
|---|---|---|
| `$schema` | string (URL) | Link to this document. |
| `format` | string | Always `lyklabord-personal-export`. |
| `formatVersion` | integer | Version of this export envelope (currently `1`). Independent of `modelSchemaVersion`. |
| `modelSchemaVersion` | integer | Version of the on-device personal-model store the data was projected from. |
| `note` | string | Human-readable one-liner (points here). |
| `exportedAt` | string (ISO-8601) | When the file was produced. |
| `learnedWords` | array | See below. |
| `userAddedWords` | array of string | Words you added by hand in the dictionary editor, sorted. |
| `tombstones` | array of string | Words you deleted, sorted. Kept so a deleted word is never silently re-learned. |
| `bigrams` | array | Word-pair counts, see below. |
| `touchStatistics` | array | Per-key adaptive touch aggregates, see below. |

## `learnedWords[]`

One entry per word currently valid as personal vocabulary (learned by
repetition or explicit acceptance, or added by hand). Pending sub-threshold
words — one-off commits, often typos — are deliberately excluded.

| Field | Type | Meaning |
|---|---|---|
| `word` | string | The surface form, exactly as committed (case-preserving). |
| `count` | integer | Total commits across all languages. |
| `icelandic` / `english` / `unknown` | integer | Per-language attribution of those commits. Attribution only — surface forms are never merged across languages or lemmas. |
| `daysSeen` | array of integer | Distinct UTC day buckets (days since 1970-01-01) the word was committed on. The coarsest temporal data the keyboard keeps — never finer than a day. |
| `explicitlyAccepted` | boolean | Learned immediately via a verbatim tap or import (survives decay). |
| `userAdded` | boolean | You added this word by hand. |

## `bigrams[]`

| Field | Type | Meaning |
|---|---|---|
| `first` | string | The preceding word. |
| `second` | string | The following word. |
| `count` | integer | How often `second` followed `first`. |

## `touchStatistics[]`

Aggregate statistics of where on each key you tend to tap, used by the
adaptive touch model. Individual taps are never stored — only these running
aggregates (Welford's online algorithm).

| Field | Type | Meaning |
|---|---|---|
| `key` | string (1 char) | The key. |
| `stats.count` | number | Effective sample count (decays over time; not necessarily an integer). |
| `stats.meanDX` / `stats.meanDY` | number | Mean tap offset from key center, in key units (1.0 = one key width/height). |
| `stats.m2DX` / `stats.m2DY` / `stats.cDXDY` | number | Sums of squared/cross deviations (for variance/covariance). |

## Privacy notes

- The file never contains running text, sentences, or anything typed in
  password / URL / email / secure fields — those are never recorded in the
  first place.
- No timestamp finer than a calendar day appears anywhere except
  `exportedAt` (the moment you pressed export).
- See [PRIVACY.md](PRIVACY.md) for the full privacy policy.
