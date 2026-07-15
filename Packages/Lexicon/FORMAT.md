# .lex binary format (v1)

Produced by `scripts/build-lexicon.py`, read by `Packages/Lexicon/Sources/Lexicon/FrequencyLexicon.swift`.
Mirrors the mmap-and-lazy-read strategy of `Packages/LemmaCore`'s `.bin` format
(same header shape, same binary-search-over-sorted-UTF-8-strings approach) —
the file is memory-mapped and never parsed into Swift collections; every
lookup is a handful of offset-based reads against the mapped buffer.

## Header (32 bytes, little-endian)

| offset | size | field             | meaning                                   |
|-------:|-----:|-------------------|--------------------------------------------|
| 0      | 4    | magic             | `0x4C584331` ("LXC1" as bytes L,X,C,1)     |
| 4      | 4    | version           | format version, `1`                        |
| 8      | 4    | unigramCount      | number of unique words                     |
| 12     | 4    | bigramCount       | number of unique (word1, word2) pairs      |
| 16     | 4    | stringPoolSize    | bytes in the string pool (padded to 4)     |
| 20     | 8    | totalUnigramTokens| u64 sum of all (scaled) unigram freqs      |
| 28     | 4    | reserved          | must be 0                                  |

All multi-byte integers are little-endian. All reads in the Swift reader use
`loadUnaligned`, so no field needs natural alignment.

## Sections (immediately after the 32-byte header, back to back)

Word ids are simply indices `0..<unigramCount` into the sorted word arrays
below — there is no separate id table.

1. **String pool** (`stringPoolSize` bytes) — concatenated UTF-8 bytes of
   every unique unigram word, in the same ascending byte order as the arrays
   below (no separators; offsets/lengths delimit each word). Padded with zero
   bytes to a multiple of 4.
2. **Word offsets** (`unigramCount` × u32) — byte offset of word `i` into the
   string pool.
3. **Word lengths** (`unigramCount` × u8, padded to a multiple of 4) — UTF-8
   byte length of word `i`. Words longer than 255 bytes cannot occur (no
   natural-language token is that long); the builder asserts this.
4. **Word frequencies** (`unigramCount` × u32) — scaled frequency of word
   `i` (see Scaling below). Parallel array to offsets/lengths: word id `i`'s
   frequency is `wordFreqs[i]`.
5. **Bigram first-word ids** (`bigramCount` × u32) — word id of the first
   token of bigram `j`.
6. **Bigram second-word ids** (`bigramCount` × u32) — word id of the second
   token of bigram `j`.
7. **Bigram frequencies** (`bigramCount` × u32) — scaled frequency of bigram
   `j`.

Bigrams are sorted ascending by `(firstWordId, secondWordId)` (i.e. by the
*sorted rank* of each word, not by the word's spelling — this is stable and
avoids re-deriving string comparisons for bigram lookups: it's just a tuple
binary search over two u32 arrays). Because the word list is itself sorted by
spelling, this is equivalent to sorting bigrams alphabetically by
`(word1, word2)` text.

No trailing padding after section 7; file length is exactly the end offset
of section 7.

## Lookup algorithms

- **`frequency(of:)`**: fold curly apostrophe (U+2019) to straight (`'`),
  lowercase + NFC-normalize the word, binary-search the word arrays
  (offsets/lengths) by raw UTF-8 byte comparison (same byte-exact,
  code-point-order comparison `BinaryLemmatizer` uses — never Swift
  `String ==`, which would apply Unicode canonical equivalence). Return
  `wordFreqs[id]` or `nil`. The apostrophe fold matters because iOS text
  input commonly emits curly apostrophes for contractions ("don't" via
  smart quotes) while the builder stores the straight-apostrophe spelling
  (see "Builder normalization rules" below) — every lookup entry point
  (`frequency`, `bigramFrequency`, `completions`, `continuations`) shares
  one `normalizedKey` helper that does this fold, so they all match
  consistently.
- **`bigramFrequency(_:_:)`**: resolve both words to ids via the word binary
  search (nil if either is unknown), then binary-search the bigram id arrays
  for `(id1, id2)`.
- **`completions(of:limit:)`**: binary-search for the lower and upper bound
  of the id range whose word has `prefix` as a byte prefix (two binary
  searches: leftmost id ≥ prefix, leftmost id ≥ prefix-with-an-appended
  maximal byte). Because words are sorted, this range is contiguous. Scan the
  range (capped at 20,000 entries — see note below), collecting
  `(word, freq)`, then return the top `limit` by descending frequency (ties
  broken by ascending word order, i.e. the existing sort order).
  **Note:** if a prefix's range exceeds 20,000 candidate words (only possible
  for very short prefixes, e.g. a single common letter, on the larger
  Icelandic table), the scan stops at 20,000 and the result is the best-of
  those-first-20k rather than a true global top-`limit`. This keeps
  `completions` O(bounded) instead of O(range) for pathological short
  prefixes; real keyboard prefixes are typically ≥2 characters by the time
  completions are shown, where ranges are small.
- **`continuations(of:limit:)`**: resolve `word` to a word id via the word
  binary search (`[]` if unknown). Bigrams are sorted by
  `(firstWordId, secondWordId)`, so every bigram beginning with that id forms
  a single contiguous range in the bigram arrays — two binary searches over
  `bigramFirstIds` alone (leftmost id `>= firstId`, leftmost id `> firstId`)
  find its bounds, no different from the two-binary-search shape
  `completions` uses over the word table. Scan the range (same 20,000-entry
  cap as `completions`, for the same defensive reason — real per-word bigram
  fan-out is far smaller in practice), collect `(secondWord, freq)`, sort by
  descending frequency (ties broken by ascending word order), and return the
  top `limit`. No format or on-disk layout change was needed: this method
  reads exactly the sections `bigramFrequency` already reads, just scanning a
  range instead of probing one pair.

## Scaling to u32

Source frequency corpora exceed `UInt32.max` (4,294,967,295) — e.g. English
unigram "the" is 26,548,583,149, and English bigram "of the" is
177,045,273,024. Each section (unigrams, bigrams) is scaled **independently**
by the builder:

```
divisor = 1 if max_count <= 0xFFFFFFFF else ceil(max_count / 0xFFFFFFFF)
scaled  = max(1, count // divisor)   # floor division, clamped to >= 1
```

Clamping to a minimum of 1 preserves the distinction between "known but
extremely rare" (freq 1) and "unknown" (`nil`/absent from the table) — a word
that survives filtering always gets a positive frequency.

For the shipped artifacts: Icelandic counts (max unigram ≈ 4.29×10⁷, max
bigram ≈ 1.66×10⁶) already fit in u32, so `divisor == 1` (no scaling, exact
counts). English counts are scaled: unigram divisor ≈ 7, bigram divisor ≈ 42
(computed at build time from the actual max in the filtered data, not
hardcoded — see `build-lexicon.py`). `totalUnigramTokens` is the u64 sum of
the *scaled* per-word frequencies actually stored, so probability
normalization (`freq / totalUnigramTokens`) stays internally consistent
within one `.lex` file. Scaled frequencies are not comparable *across* the
two shipped languages' files, only within a single file.

## Builder normalization rules (`scripts/build-lexicon.py`)

- Lowercase, fold curly apostrophe (U+2019, `’`) to the straight ASCII
  apostrophe (`'`), then Unicode NFC-normalize every word.
- Keep only words matching `^[a-zþðæöáéíóúý]+('[a-zþðæöáéíóúý]+)*$` after
  lowercasing (ASCII letters + Icelandic-specific letters, with **internal**
  apostrophes allowed so contractions/possessives like `don't`, `o'clock`,
  `y'all` survive — a leading, trailing, or doubled apostrophe still fails
  the match). Anything else (digits, punctuation, multi-token phrases) is
  dropped. This removes things like `.`, `,`, `nr.` from the raw sources
  while keeping apostrophe forms that pass the pattern.
  - **History**: format v1 originally disallowed apostrophes entirely
    (`^[a-zþðæöáéíóúý]+$`), which silently deleted every contraction in
    `en-80k.txt` even though the source already contained them (e.g.
    `don't 188045`, `i'm 93673`) — this is what caused the harness-observed
    `don't` → `dont` → `Ibm`-style autocorrect corruption. Fixed by widening
    `WORD_RE`; no on-disk format change, since apostrophe is just another
    byte in the UTF-8 string pool.
- **Contraction backfill**: after loading unigrams, a curated list of common
  English contractions (`CONTRACTION_EXPANSIONS` in the builder — `don't`,
  `i'm`, `it's`, `can't`, `won't`, `isn't`, `you're`, `we're`, `they're`,
  `i've`, `i'll`, `didn't`, `doesn't`, `wasn't`, `aren't`, `couldn't`,
  `wouldn't`, `shouldn't`, `that's`, `there's`, `what's`, `let's`) is checked
  against the unigram table. Ones already present (all of them, for the
  current `en-80k.txt`) are left untouched. Any that are still missing get a
  derived frequency `freq(contraction) = bigram_freq(uncontracted_phrase) // 2`
  computed from the *raw* bigram source (e.g. `freq("don't") ≈
  bigram_freq("do", "not") // 2`) — a same-corpus proxy, since Google Ngram
  unigram and bigram counts are comparable orders of magnitude (see
  "Scaling to u32" below). This is a fallback for future source drift, not
  active against the currently shipped data.
- Bigram entries where either word fails that filter, or where either word
  is not present in the (filtered) unigram set, are **dropped** — bigrams are
  never used to grow the unigram vocabulary. This keeps the unigram table
  the single source of truth for "is this word known" and keeps
  `bigramFrequency` reducible to two unigram lookups. Note the SymSpell
  bigram source (`frequency_bigramdictionary_en_243_342.txt`) contains zero
  apostrophes, so no contraction ever appears as a bigram's first or second
  word — contractions get unigram frequencies (for `frequency(of:)`
  ranking) but not bigram/continuation entries from this source.
- Duplicate unigram words after normalization (e.g. two casings of the same
  word) have their counts summed before scaling.
- Duplicate bigram pairs after normalization likewise have counts summed.
