# Language Data Artifacts

This directory contains the language models and frequency tables for the better-keyboard iOS extension. All files are mmap-ed in the app bundle for efficient on-device autocorrect and prediction.

## Icelandic (is/)

### Binary Lemma Models

These are indexed trie-based binary artifacts generated from BÍN (Beygingarlýsing íslensks nútímamáls) via the lemma-is project. Each maps surface forms to (lemma id, frequency, flags) tuples.

- **lemma-is.bin** (95,416,256 bytes) — **PRIMARY**
  - Full BÍN: 3,071,066 word forms, 289,124 lemmas, format v2 with morphological data + 414,007 bigrams
  - Measured (Swift mmap bench, 2026-07-15): phys_footprint +0.28 MB after load + 1000 lookups; 124 µs/lookup; 0.4 ms load
  - Ship this. mmap makes file size irrelevant to the extension memory cap; only cost is app download size

- **lemma-is.core.bin** (9,669,628 bytes)
  - Smaller alternative (350k forms, no morph/bigrams, v1); kept for tests and as a download-size escape hatch

- **lemma-is.core.top_200k.bin** (5,638,556 bytes)
  - Fallback tier for older/memory-constrained devices
  - Top 200k most frequent Icelandic words by corpus frequency
  - Deployment: A/B test or enable on devices with <2GB available memory

- **lemma-is.core.min_100.bin** (1,932,984 bytes)
  - Emergency floor for extremely constrained environments
  - Minimal vocabulary covering only the most essential words (frequency ≥ 100 in corpus)
  - Deployment: Ultra-low-memory devices, if needed for v1 ship

### Frequency Tables

- **unigrams.json.gz** (2,037,976 bytes)
  - Gzipped JSON: word → frequency count
  - Used by the predictor and learning store for next-word prediction
  - Source: Icelandic corpus from lemma-is

- **bigrams.json.gz** (3,041,400 bytes)
  - Gzipped JSON: (word1, word2) → co-occurrence count
  - Used for bigram-based prediction and context weighting
  - Source: Icelandic corpus from lemma-is

### Provenance

All Icelandic data is derived from **BÍN** (Beygingarlýsing íslensks nútímamáls), a comprehensive morphological database of Modern Icelandic.

- **Source**: Árni Magnússon Institute for Icelandic Studies, https://bin.arnastofnun.is
- **Processing pipeline**: lemma-is project (`build-binary.py`, `extract-*grams.py`)
- **Frequency corpus**: Icelandic web corpus and published texts
- **Conversion method**: Lemma-indexed trie with frequency ranks; inflected surface forms mapped to lemma IDs

### License & Attribution

See `ATTRIBUTION.md` for full credit text. In brief:
- Data derived from BÍN, © Árni Magnússon Institute for Icelandic Studies
- License terms: Credit required, no raw-data redistribution, no publishing of inflection paradigms (all cleared for this project; see email thread)
- This keyboard extension stores derived forms only (trie indices + lemma pointers), not raw paradigm data

## English (en/)

### Frequency Dictionary

- **en-80k.txt** (1,282,042 bytes)
  - Plain text: 80,000 most frequent English words, one per line
  - Format: `word<space>frequency_count` (e.g., `the 26548583149`)
  - 80k entries covering ~99% of English text by token frequency
  - Source: SymSpell project (wolfgarbe/SymSpell)
  - Processing: Intersection of Google Ngram dataset with Hunspell dictionary wordlists

### Bigram Dictionary

- **frequency_bigramdictionary_en_243_342.txt** (5,137,213 bytes; 242,342 entries)
  - Format: `word1 word2<space>frequency_count` (e.g., `abcs of 10956800`)
  - Source: SymSpell project, `SymSpell/frequency_bigramdictionary_en_243_342.txt` (MIT)
  - URL: https://raw.githubusercontent.com/wolfgarbe/SymSpell/master/SymSpell/frequency_bigramdictionary_en_243_342.txt
  - Used for English next-word prediction and compound-correction context

### Provenance & License

- **Source**: SymSpell repository (https://github.com/wolfgarbe/SymSpell)
- **License**: MIT
- **Frequency data**: Google Ngrams v2 (public domain) intersected with Hunspell dictionaries (various open licenses)
- **Citation**: See `ATTRIBUTION.md`

## File Roles in the Keyboard Extension

### On-Device Autocorrect

1. User types a word → runs through spatial key-distance model (fat-finger compensation)
2. Corrector stage uses SymSpell edit-distance candidates (English: en-80k.txt; Icelandic: lemma-is.core.bin)
3. Re-rank candidates by language model frequency and language ID estimate (per-word blending)
4. Return top 1–3 suggestions to UI

### Next-Word Prediction

1. User completes a word → reads unigrams.json.gz + bigrams.json.gz (optional, Icelandic only for v1)
2. Score P(next_word | prev_word, LID_estimate)
3. Blend IS/EN via running LID classifier
4. Display top 1–2 predictions in suggestion bar

### On-Device Learning

- Personal unigrams/bigrams log in App Group container (append-only, mmap-ed read)
- Overlay outranks base models in predictor
- Learned words/bigrams synced to iCloud CloudKit (encrypted)
- User can delete individual words/patterns from learned store (tombstone record)

## Tiering Strategy (obsolete — kept for context)

Device-based tiering was designed before the Swift mmap bench proved footprint is independent of file size (all tiers measure ~+0.25 MB phys_footprint; even the 91 MB full binary measures +0.28 MB). Decision 2026-07-15: **ship the full lemma-is.bin on all devices**. The smaller tiers remain staged only as a download-size escape hatch and for fast unit tests.

| File | Size | Contents (words / lemmas / bigrams) |
|------|------|--------------------------------------|
| lemma-is.bin (primary) | 91.0 MB | 3,071,066 / 289,124 / 414,007 (v2, morph) |
| lemma-is.core.bin | 9.2 MB | 350,000 / 81,587 / 0 (v1) |
| lemma-is.core.top_200k.bin | 5.4 MB | 200,000 forms (v1) |
| lemma-is.core.min_100.bin | 1.8 MB | freq ≥ 100 forms (v1) |

**Note**: mmap pages are file-backed and do not count against the extension dirty-memory (jetsam) limit. Paging is lazy and demand-driven.

## .lex artifacts

Compact mmap-able unigram+bigram frequency tables for ranking/prediction,
distinct from the lemma-is `.bin` trie above (which answers "is this a valid
form + what's its lemma", not "how frequent is it"). Built by
`scripts/build-lexicon.py` from the sources documented earlier in this file;
read by `Packages/Lexicon`'s `FrequencyLexicon` (mmap, lazy offset reads, no
upfront parsing — same strategy as `BinaryLemmatizer`). Format is documented
in `Packages/Lexicon/FORMAT.md`.

Both builds drop tokens with non-letter characters (digits, punctuation) but
now allow a single **internal** apostrophe (`'`/`'`, curly folded to
straight) so contractions survive — see "Contraction fix" below and
FORMAT.md for the exact filter and the u32-scaling algorithm.

**Rebuilt 2026-07-15** to fix two harness-found quirks (contractions
destroyed in en.lex, unaccented/junk ranking noise in is.lex — see PLAN.md
"Harness-found quirk list"). Old sizes kept here for the record:

| artifact | before (2026-07-15 AM) | after (2026-07-15 PM) |
|---|---|---|
| en/en.lex | 4,265,360 bytes / 4.07 MB — 79,851 unigrams, 240,966 bigrams | 4,267,624 bytes / 4.07 MB — **80,000** unigrams, 240,966 bigrams |
| is/is.lex | 10,935,572 bytes / 10.43 MB — 308,649 unigrams, 381,547 bigrams | 9,658,112 bytes / 9.21 MB — **242,835** unigrams, 380,092 bigrams |

### Contraction fix (en.lex)

**Root cause**: format v1's builder filter (`WORD_RE = ^[a-zþðæöáéíóúý]+$`)
disallowed apostrophes entirely, so every contraction was silently dropped
after loading — even though `en-80k.txt` already contains them with real
frequencies (`don't 188045`, `i'm 93673`, etc., from the SymSpell/Google
Ngram source). This is what caused the harness-observed corruption
(`don't` → `dont` → autocorrected to `Ibm`). Fix: `WORD_RE` now allows a
single internal apostrophe cluster
(`^[a-zþðæöáéíóúý]+('[a-zþðæöáéíóúý]+)*$`, leading/trailing/doubled
apostrophes still rejected), and the curly apostrophe (U+2019) is folded to
straight (`'`) before matching/storing — both at build time
(`build-lexicon.py`'s `normalize_word`) and at query time
(`FrequencyLexicon.normalizedKey`, since iOS text input commonly emits curly
apostrophes for contractions). No format change was needed — apostrophe is
just another UTF-8 byte in the string pool.

Result: en.lex unigrams 79,851 → 80,000 (+149, all apostrophe forms that
were previously being silently dropped). All 22 curated contractions
(`don't`, `i'm`, `it's`, `can't`, `won't`, `isn't`, `you're`, `we're`,
`they're`, `i've`, `i'll`, `didn't`, `doesn't`, `wasn't`, `aren't`,
`couldn't`, `wouldn't`, `shouldn't`, `that's`, `there's`, `what's`, `let's`)
were already present in the source once the filter allowed them — none
needed the fallback derivation. That fallback (opt-in via
`--contraction-backfill`, English-only) exists for future source drift: if a
curated contraction is ever missing, its frequency is derived as
`bigram_freq(uncontracted_phrase) // 2` from the raw SymSpell bigram source
(e.g. `freq("don't") ≈ bigram_freq("do", "not") // 2` — a same-corpus proxy,
since Google Ngram unigram/bigram counts are comparable orders of
magnitude). The SymSpell bigram source itself contains zero apostrophes, so
contractions get unigram frequencies (ranking) but no bigram/continuation
entries from this source — not fabricated, since there's no grounded way to
derive them.

### Ranking-noise pruning (is.lex)

is.lex is **ranking-only** — validity comes from BÍN via `lemma-is.bin` in
the engine, so aggressive pruning here is safe (a pruned word just stops
being suggested/ranked, it doesn't become "invalid"). Two prunes now run via
`--bin-lookup`/`--bin-lemmas` (pointing at lemma-is's
`data-dist/lookup.tsv.gz` and `data-dist/lemmas.txt.gz`):

1. **BÍN-membership prune**: drop any unigram that isn't a BÍN surface form,
   *except* the top 10,000 most frequent non-BÍN words (`--bin-topk`,
   default 10000) and any non-BÍN word at/above frequency 2,000
   (`--bin-high-freq`, default 2000) — these two escape hatches keep
   legitimate non-BÍN vocabulary a news-corpus-trained table is full of:
   foreign proper nouns, sports teams/clubs, orgs, abbreviations, English
   loanwords ("united", "manchester", "arsenal", "esb", "bbc", "rúv", single
   letters used as initials). **Gotcha found during implementation**:
   `lookup.tsv.gz` alone is *not* the full BÍN form set — lemma-is's
   `build-data.py` deliberately omits any word that is its own lemma with no
   other lemma/POS ambiguity (a lemma-lookup index has nothing useful to say
   about a word already equal to its own lemma). That skip rule excludes
   huge swaths of basic vocabulary: pronouns (`hann`, `ég`), nominative
   singular nouns (`hestur`), common adverbs (`einnig`), proper nouns
   (`reykjavík`) — none of these are in `lookup.tsv.gz`, but all are in
   `lemmas.txt.gz`. The builder unions both files; using `lookup.tsv.gz`
   alone would have flagged ~35% of common Icelandic vocabulary as "non-BÍN
   noise" and pruned it. Result: 308,649 → 243,258 unigrams (65,391 dropped
   as non-BÍN noise, 10,000 non-BÍN words kept via the escape hatches).
2. **Accent-dominance filter** (`--accent-ratio`, default 10): drop an
   unaccented word when an accented variant exists (folding `á,é,í,ó,ú,ý,ö`
   — each an NFD-decomposable base+diacritic — down to its ASCII base
   letter; `þ,ð,æ` are independent letters with no ASCII fallback and are
   left alone) whose frequency is ≥10x the unaccented word's. This targets
   the specific "accents dropped by a non-Icelandic input method" noise
   pattern. Result: 243,258 → 242,835 unigrams (423 dropped), e.g. `i`
   (37,299) dominated by `í` (25,371,808), `a` (106,173) dominated by `á`
   (18,227,685), `eg` (6,359) dominated by `ég` (1,907,515).

**Spot-check** (both filters combined, verified in
`Packages/Lexicon/Tests/LexiconTests/FrequencyLexiconTests.swift`):
- `islenskar`/`islensk` (unaccented noise): **gone** — dropped by the
  accent-dominance filter (their accented counterparts `íslenskar`/`íslensk`
  outweigh them >1000x), and also not in the BÍN top-K/high-freq escape
  hatch (freq 5/7, deep in the non-BÍN tail).
- `hester` (junk form, freq 57): **gone** — not a BÍN form (not in
  `lookup.tsv.gz` or `lemmas.txt.gz`), and its frequency puts it well
  outside the top-10,000 non-BÍN escape hatch.
- `íslenskar` (15,388), `íslensk` (37,988), `hestur` (422, kept via
  `lemmas.txt.gz` despite `lookup.tsv.gz`'s gap), `hann` (3,772,234), `ég`
  (1,907,515), `reykjavík` (kept via the non-BÍN top-K escape hatch): **all
  survive** with their real frequencies.

**Total**: is.lex unigrams 308,649 → 242,835 (66,238 dropped, ~21.5%
reduction); bigrams 381,547 → 380,092 (1,455 fewer, since bigrams referencing
a now-pruned word are dropped along with it — same rule as always: bigrams
never grow or preserve vocabulary beyond the unigram table). File size
10.43 MB → 9.21 MB (12% smaller, roughly proportional-ish to the unigram
count drop — string pool + fixed-width arrays both shrink).

Bench (`swift run -c release lex-bench <path>`, macOS, 1000 iterations each,
rebuilt artifacts):

| artifact | load | frequency() | bigramFrequency() | completions() |
|---|---|---|---|---|
| en.lex | 0.26 ms | 2.0 µs/call | 5.5 µs/call | 135.5 µs/call |
| is.lex | 0.43 ms | 7.0 µs/call | 5.0 µs/call | 846.5 µs/call |

`completions()` cost is dominated by short single-letter prefixes in the
bench word mix, which hit the documented 20k-entry scan cap on the larger
Icelandic table; real keyboard prefixes are typically ≥2 characters, where
ranges are far smaller. phys_footprint delta after load + 3000 mixed lookups:
+0.86 MB (en.lex), +2.13 MB (is.lex) — both file-backed mmap, so this is
almost entirely the materialized `String`/tuple results, not resident file
pages. Footprint stayed flat vs. the pre-rebuild bench (+0.97 MB / +2.63 MB)
— if anything slightly better, since is.lex itself shrank.

## CI Checks (Future)

- [ ] Verify total binary sizes on each tier ≤ 35 MB in app bundle (ipa)
- [ ] On-device memory ceiling test: launch keyboard with full model stack, confirm dirty memory < 50 MB on iPhone 8 (1 GB baseline + 30 MB model headroom)
- [ ] Frequency table JSON schema validation (gzip integrity + JSON parse)
- [ ] Bigram fallback: if bigrams.json.gz is missing, log warning and degrade to unigrams-only
