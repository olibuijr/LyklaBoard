# Autocorrect Eval Datasets

Corpus-derived typo→intended evaluation pairs for the TypeEngine autocorrect
stack — the data half of the eval studio (PLAN.md testing pyramid tier 1,
`type-eval`). Built 2026-07-15.

## Files

| file | contents |
|---|---|
| `sentences.is.txt` | 7,183 clean Icelandic sentences, one per line, NFC, deduplicated |
| `sentences.en.txt` | 7,598 clean English sentences, one per line, NFC, deduplicated |
| `sources.is.jsonl` | per-article provenance manifest (pageid, title, sentences contributed) |
| `sources.en.jsonl` | same, for English |
| `dev.jsonl` | 3,000 typo pairs (1,500 IS + 1,500 EN) — **tuning allowed** |
| `heldout.jsonl` | 3,000 typo pairs (1,500 IS + 1,500 EN) — **never tune against, only report** |
| `compounds.jsonl` | 666 real compound-error pairs (wave 31, iceErrorCorpus + GreynirCorrect) — see "Compounds slice" below |
| `generate-compounds-eval.py` | deterministic generator for `compounds.jsonl` (reads `research/mideind-compound-cases.jsonl`, probes validity through `type-repl`) |

## THE RULE: heldout.jsonl is report-only

`heldout.jsonl` must **never** be used for tuning — no threshold sweeps, no
weight fitting, no error analysis that feeds back into engine changes, no
"just checking how we do on heldout" during development iterations. It exists
to produce the honest number reported at the end of a work wave. All
tuning/iteration happens against `dev.jsonl`. If heldout ever gets burned
(someone tunes against it), regenerate both splits with a new `--seed` and
freshly fetched sentence corpora, and note the burn here.

The splits are safe by construction: sentences are shuffled and split into
two disjoint pools **before** any pair generation (a sentence contributes
pairs to dev or heldout, never both), so no heldout sentence's vocabulary,
context, or typo slots were visible during dev generation.

## Compounds slice (`compounds.jsonl`, wave 31)

Real error→correction pairs from the **Icelandic Error Corpus** (IceEC, CC BY
4.0 — attribution in `data/ATTRIBUTION.md`) plus 16 GreynirCorrect test
assertions (MIT), filtered to the compound error classes and reshaped for the
`type-eval corpus compounds` replay harness. Unlike dev/heldout these are not
synthetic: they are the compound errors real writers actually make. Run by
`type-eval scorecard` on every commit (its own JSON key, `compounds`) — NOT a
hard gate, and NOT part of the dev/heldout tuning discipline (its history
keeps comparability by never being folded into `dev.jsonl`).

| category | n | replay shape | measures |
|---|---|---|---|
| `compound_collocation` | 250 | typo → intended, single token | linking-letter / spelling errors inside compounds (framhaldskóla→framhaldsskóla) — the corrector-target class |
| `missing_hyphen` | 106 | joined typo → hyphenated intended | Porschebílunum→Porsche-bílunum; the wave-31 hyphen-join repair reaches the capitalized-foreign-modifier shape |
| `missing_hyphen_spaced` | 100 | context=[A], typo=B, intended=A-B | cross-token hyphen join — **structural gap** (no join machinery), doubles as a protection assertion: any autocorrect fire on the valid token B is a false-ac |
| `wrongly_joined` | 10 | joined typo → two-word intended | the never-a-compound deny set (margskonar→margs konar): split offer must top the bar |
| `wrongly_split` | 200 | context=[A], typo=B, intended=AB | wrongly split compounds — **structural gap** (cross-token join), same protection-assertion property |

Selection discipline (full detail in the generator's docstring): shape-pure
rows only (exact join/hyphen shapes — TEI alignment noise dropped), deduped,
typo-validity filtered through the real artifacts (a lexicon/BÍN-valid
"typo" can never be a corrector target under the conservatism invariant —
except the deny-listed `wrongly_joined` words, which measure the offer), and
md5-stratified caps per category. Regeneration:

```bash
python3 data/eval/generate-compounds-eval.py   # deterministic
```

The `context` field of the transformed categories holds the real first token
of the original two-token error; everything else replays context-free.

## Source provenance + licenses

Both sentence corpora are random-article plain-text extracts fetched live
from Wikipedia via the public MediaWiki API (`prop=extracts&explaintext=1`),
cleaned and sentence-split by `scripts/fetch-eval-corpora.py`:

- **Icelandic**: is.wikipedia.org — license **CC BY-SA 4.0**
  (https://creativecommons.org/licenses/by-sa/4.0/). Attribution:
  Wikipedia contributors; the per-article manifest in `sources.is.jsonl`
  lists every contributing article (631 articles).
- **English**: en.wikipedia.org — license **CC BY-SA 4.0**, same terms.
  Manifest: `sources.en.jsonl` (403 articles).

The sentence files are derivative works of Wikipedia text and are
redistributed here under CC BY-SA 4.0 (share-alike applies to these data
files, independent of the repo's code license).

### Sources considered and rejected

- **IFD corpus** (lemma-is sibling repo, `data/ifd/ifd.jsonl`, 36,186
  gold-tagged Icelandic sentences — checked first per the task brief): clean
  and ideal linguistically, but its CLARIN "Icelandic Frequency Dictionary"
  license (https://repository.clarin.is/repository/xmlui/page/license-frequency-dictionary)
  is a research-only grant that explicitly forbids giving third parties
  access to any part of the corpus. Committing IFD-derived sentences to this
  public repo would violate that. **Not used** — this is the main
  acquisition gap; the linguistically-curated IS eval upgrade would need a
  properly licensed corpus (e.g. IGC-2024, CC BY 4.0, via HuggingFace
  `arnastofnun/IGC-2024` — see lemma-is `tests/igc-2024.test.ts` for a
  fetch precedent).
- **OSCAR / CC-100 Icelandic**: bulk multi-GB dumps of noisier web-scrape
  text; Wikipedia extracts are cleaner per byte and license-clear.
- **Project Gutenberg / Leipzig English news** (suggested in the brief):
  viable (public domain / CC BY resp.), but using Wikipedia for English too
  keeps one acquisition+cleaning pipeline, an identical selection process
  for both languages, and one license story. Note the register trade-off:
  encyclopedic prose is not keyboard-typed chat; see Limitations.

## Error model

Generated by `scripts/generate-eval-pairs.py` (stdlib only, deterministic —
same seed + same sentence files ⇒ byte-identical output; verified).

### Taxonomy and weights

Relative weights (sum to 100, so they read as percentages of each
language's pairs). Quota-driven sampling makes realized counts match these
weights exactly (largest-remainder rounding):

| category | IS | EN | mechanics |
|---|---|---|---|
| substitution | 28 | 28 | replace a letter with a physically adjacent key on the **Icelandic QWERTY layout** (rows `qwertyuiopð` / `asdfghjklæö` / `zxcvbnmþ`, half-key-stagger adjacency incl. diagonals; EN pairs use the same geometry minus ð/æ/ö/þ since EN words don't contain IS-only letters and typing EN on the IS layout only differs at those keys' neighbors) |
| insertion | 18 | 18 | insert a key adjacent to the neighboring letter |
| deletion | 17 | 17 | drop one letter |
| transposition | 7 | 7 | swap two adjacent (different) letters |
| gemination | 6 | 6 | double a letter, or collapse an existing double (60/40 collapse-vs-double when a double exists) |
| space_miss | 8 | 8 | merge two space-separated words: space dropped (50%) or replaced by a space-row letter c/v/b/n/m (50%) — matches PLAN.md "Space-miss correction" (the "Smelirna" dogfood bug class) |
| accent_drop | 16 | — | á é í ó ú ý ö → ascii base (same fold as `build-lexicon.py`'s accent-dominance filter; þ/ð/æ have no ascii base and are excluded) |
| contraction_damage | — | 16 | drop apostrophe(s): contractions and possessives (`don't`→`dont`, `Billboard's`→`Billboards`; curly `’` handled) |

### Rationale

- The classic four single-edit types follow the task brief's baseline
  (substitution 40 : insertion 25 : deletion 25 : transposition 10 — the
  standard single-error taxonomy from Damerau 1964 as surveyed in Kukich
  1992), rescaled to 70% of total mass: 28/18/17/7.
- The remaining 30% funds the categories this engine specifically must win:
  gemination 6% (Icelandic double-consonant orthography makes this a real IS
  failure class; kept for EN symmetry), space_miss 8% (dedicated PLAN.md
  feature), and 16% for the per-language booster — accent_drop for IS
  (dominant real-world IS noise pattern, per the is.lex accent-dominance
  data) and contraction_damage for EN (harness-found "I'm→Ibm" quirk class).
- **Aalto ITE calibration attempt**: we tried to fetch the ITE paper's own
  error-type frequency breakdown (https://zenodo.org/doi/10.5281/zenodo.12528162)
  to replace the literature baseline; the public preprint reports ITE
  usage/accuracy metrics, not a substitution/insertion/deletion/transposition
  split, and the PDF mirror returned 403. Fell back to the brief's
  literature values as instructed. Revisit if/when the 7.3GB dataset is
  downloaded for the replay rig (research/typing-datasets.md) — the
  keystroke logs contain raw errors from which a real mixture could be fit.

### Record format (JSONL)

```json
{"typo": "hlutiHvalfjarðarsveitar", "intended": "hluti Hvalfjarðarsveitar",
 "context": ["Frá", "júní"], "lang": "is", "category": "space_miss", "seed": 20260715}
```

- `context`: up to 8 real word tokens immediately preceding the target in
  the source sentence (word tokens only — punctuation/digits stripped).
- `intended` for `space_miss` is the two-word string `"word1 word2"`;
  for all other categories a single word.
- `seed`: the run seed (provenance).

### Sampling constraints

- Sentences shuffled + pool-split (dev/heldout) before generation; per
  category, sentences are visited in a category-specific deterministic
  shuffle; max 3 pairs per sentence; no token slot used twice.
- Single-word targets are ≥3 letters; space_miss halves ≥2 letters each,
  strictly single-space separated in the source sentence.
- Enforced invariants: `typo != intended` (all 6,000 records);
  `context + intended` appears contiguously in the token stream of a real
  pool sentence (verified on 400-record samples per file, 0 failures).

## Pair counts (per split, per language — realized == quota)

Each split: 3,000 pairs = 1,500 IS + 1,500 EN.

| category | IS dev | EN dev | IS heldout | EN heldout |
|---|---|---|---|---|
| substitution | 420 | 420 | 420 | 420 |
| insertion | 270 | 270 | 270 | 270 |
| deletion | 255 | 255 | 255 | 255 |
| transposition | 105 | 105 | 105 | 105 |
| gemination | 90 | 90 | 90 | 90 |
| space_miss | 120 | 120 | 120 | 120 |
| accent_drop | 240 | — | 240 | — |
| contraction_damage | — | 240 | — | 240 |
| **total** | **1500** | **1500** | **1500** | **1500** |

## Regeneration

```bash
# 1. Fetch fresh sentence corpora (network; ~4-6 min each; random articles,
#    so output differs per run — the pair generator is what's deterministic)
python3 scripts/fetch-eval-corpora.py --lang is --target 7000 --out-dir data/eval
python3 scripts/fetch-eval-corpora.py --lang en --target 7000 --out-dir data/eval

# 2. Generate pairs (deterministic given the sentence files + seed)
python3 scripts/generate-eval-pairs.py \
    --sentences-dir data/eval --out-dir data/eval \
    --seed 20260715 --dev-target 3000 --heldout-target 3000
```

Shipped files were produced with seed `20260715`. Regenerating pairs from
the shipped sentence files with that seed reproduces `dev.jsonl` /
`heldout.jsonl` byte-for-byte (md5-verified).

## Limitations / acquisition gaps

- **Register mismatch**: Wikipedia is encyclopedic prose, not mobile chat.
  Proper nouns and formal vocabulary are over-represented vs. real keyboard
  input; contractions are so rare in encyclopedic English that the
  contraction_damage quota is mostly fed by possessives (`Group's`,
  `men's`) rather than `don't`/`I'm` — acceptable for apostrophe-handling
  evals but note it when reading results. A chat/dialogue-register corpus
  (e.g. OpenSubtitles, permissively licensed subsets) would be the upgrade.
- **IFD unusable** for a public repo (research-only license, see above);
  IGC-2024 (CC BY 4.0) is the flagged replacement for curated Icelandic.
- **Error weights are literature values**, not fit to measured mobile-typing
  data (Aalto ITE breakdown unavailable without the full dataset download).
- **Sentence splitting is heuristic** (regex + abbreviation list); residual
  fragments from unusual abbreviations survive at a low rate. Filters
  (length 30–240 chars, ≥5 words, must start uppercase / end in
  terminator, digit-ratio cap, no URLs/markup) keep the worst out.
- `context` strips punctuation/digits, so it is a token list, not a
  verbatim substring of the sentence.
