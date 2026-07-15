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

- **`frequency(of:)`**: lowercase + NFC-normalize the word, binary-search the
  word arrays (offsets/lengths) by raw UTF-8 byte comparison (same
  byte-exact, code-point-order comparison `BinaryLemmatizer` uses — never
  Swift `String ==`, which would apply Unicode canonical equivalence).
  Return `wordFreqs[id]` or `nil`.
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

- Lowercase, then Unicode NFC-normalize every word.
- Keep only words matching `^[a-zþðæöáéíóúý]+$` after lowercasing (ASCII
  letters + Icelandic-specific letters). Anything else (digits, punctuation,
  apostrophes, multi-token phrases) is dropped. This removes things like
  `.`, `,`, `nr.`, `o'clock` from the raw sources.
- Bigram entries where either word fails that filter, or where either word
  is not present in the (filtered) unigram set, are **dropped** — bigrams are
  never used to grow the unigram vocabulary. This keeps the unigram table
  the single source of truth for "is this word known" and keeps
  `bigramFrequency` reducible to two unigram lookups.
- Duplicate unigram words after normalization (e.g. two casings of the same
  word) have their counts summed before scaling.
- Duplicate bigram pairs after normalization likewise have counts summed.
