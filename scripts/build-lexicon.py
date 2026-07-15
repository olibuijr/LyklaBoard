#!/usr/bin/env python3
"""Build a `.lex` frequency binary — see Packages/Lexicon/FORMAT.md for the
byte layout this writes and Packages/Lexicon/Sources/Lexicon/FrequencyLexicon.swift
for the reader.

Usage:
    python3 scripts/build-lexicon.py \\
        --unigrams data/en/en-80k.txt \\
        --bigrams data/en/frequency_bigramdictionary_en_243_342.txt \\
        --out data/en/en.lex

    python3 scripts/build-lexicon.py \\
        --unigrams data/is/unigrams.json.gz \\
        --bigrams data/is/bigrams.json.gz \\
        --out data/is/is.lex

Input formats (auto-detected by gzip magic bytes):
  --unigrams: either
    - text, one entry per line: "word<space>count" (e.g. data/en/en-80k.txt)
    - gzipped JSON object {word: count, ...} (e.g. data/is/unigrams.json.gz)
  --bigrams: either
    - text, one entry per line: "word1 word2<space>count"
      (e.g. data/en/frequency_bigramdictionary_en_243_342.txt)
    - gzipped JSON. Two shapes are accepted:
        - a list of [word1, word2, count] triples
          (this is the actual shape of data/is/bigrams.json.gz)
        - an object {"word1 word2": count, ...} or {word1: {word2: count}}
          (accepted defensively; not required by the shipped data)

Normalization: lowercase + NFC, keep only tokens matching
^[a-zþðæöáéíóúý]+$ (ASCII letters + Icelandic-specific letters). Everything
else (digits, punctuation, apostrophes, multi-token phrases) is dropped.
Bigrams where either word fails that filter, or where either word isn't in
the (filtered) unigram set, are dropped entirely — bigrams never grow the
unigram vocabulary. Duplicate keys (after normalization) have their counts
summed before scaling.

Frequencies are scaled to fit u32 when source counts exceed it (English
counts do; Icelandic counts don't). See FORMAT.md "Scaling to u32" for the
exact algorithm — it's also implemented below in scale_to_u32().

Stdlib only.
"""
import argparse
import gzip
import json
import re
import struct
import unicodedata

MAGIC = 0x4C58_4331  # "LXC1"
VERSION = 1
U32_MAX = 0xFFFFFFFF

WORD_RE = re.compile(r'^[a-zþðæöáéíóúý]+$')


def is_gzip(path):
    with open(path, 'rb') as f:
        return f.read(2) == b'\x1f\x8b'


def normalize_word(w):
    """Lowercase + NFC; return None if it doesn't survive the letter filter."""
    w = unicodedata.normalize('NFC', w.lower())
    if not WORD_RE.match(w):
        return None
    return w


def load_unigrams(path):
    counts = {}
    if is_gzip(path):
        with gzip.open(path, 'rt', encoding='utf-8') as f:
            raw = json.load(f)
        if not isinstance(raw, dict):
            raise ValueError(f'unexpected unigram JSON shape in {path}: {type(raw).__name__}')
        items = raw.items()
    else:
        def _iter_text():
            with open(path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.rstrip('\n')
                    if not line:
                        continue
                    parts = line.rsplit(' ', 1)
                    if len(parts) != 2:
                        continue
                    yield parts[0], parts[1]
        items = _iter_text()

    for word, count in items:
        nw = normalize_word(word)
        if nw is None:
            continue
        counts[nw] = counts.get(nw, 0) + int(count)
    return counts


def load_bigrams(path):
    """Returns a list of (word1, word2, count) triples, pre-filter — the
    caller normalizes and intersects with the unigram set."""
    triples = []
    if is_gzip(path):
        with gzip.open(path, 'rt', encoding='utf-8') as f:
            raw = json.load(f)
        if isinstance(raw, list):
            # Actual shape of data/is/bigrams.json.gz: [[w1, w2, count], ...]
            for entry in raw:
                if len(entry) != 3:
                    continue
                w1, w2, count = entry
                triples.append((w1, w2, int(count)))
        elif isinstance(raw, dict):
            for k, v in raw.items():
                if isinstance(v, dict):
                    for w2, count in v.items():
                        triples.append((k, w2, int(count)))
                else:
                    parts = k.split(' ', 1)
                    if len(parts) == 2:
                        triples.append((parts[0], parts[1], int(v)))
        else:
            raise ValueError(f'unexpected bigram JSON shape in {path}: {type(raw).__name__}')
    else:
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line:
                    continue
                parts = line.rsplit(' ', 1)
                if len(parts) != 2:
                    continue
                words_part, count_s = parts
                word_bits = words_part.split(' ')
                if len(word_bits) != 2:
                    continue
                triples.append((word_bits[0], word_bits[1], int(count_s)))
    return triples


def scale_to_u32(counts_by_key):
    """counts_by_key: dict key -> int count (arbitrary size).
    Returns (dict key -> scaled UInt32-safe count, divisor used)."""
    if not counts_by_key:
        return {}, 1
    max_count = max(counts_by_key.values())
    if max_count <= U32_MAX:
        divisor = 1
    else:
        divisor = -(-max_count // U32_MAX)  # ceil division
    scaled = {k: max(1, v // divisor) for k, v in counts_by_key.items()}
    return scaled, divisor


def build(unigrams_path, bigrams_path, out_path):
    unigram_counts = load_unigrams(unigrams_path)
    if not unigram_counts:
        raise ValueError('no valid unigrams survived normalization/filtering')

    raw_bigrams = load_bigrams(bigrams_path)

    bigram_counts = {}
    dropped_bigrams = 0
    for w1, w2, count in raw_bigrams:
        nw1 = normalize_word(w1)
        nw2 = normalize_word(w2)
        if nw1 is None or nw2 is None or nw1 not in unigram_counts or nw2 not in unigram_counts:
            dropped_bigrams += 1
            continue
        key = (nw1, nw2)
        bigram_counts[key] = bigram_counts.get(key, 0) + count

    scaled_unigrams, uni_divisor = scale_to_u32(unigram_counts)
    scaled_bigrams, bi_divisor = scale_to_u32(bigram_counts)

    sorted_words = sorted(scaled_unigrams.keys(), key=lambda w: w.encode('utf-8'))
    word_id = {w: i for i, w in enumerate(sorted_words)}

    pool = bytearray()
    word_offsets = []
    word_lengths = []
    for w in sorted_words:
        b = w.encode('utf-8')
        if len(b) > 255:
            raise ValueError(f'word too long ({len(b)} bytes): {w!r}')
        word_offsets.append(len(pool))
        word_lengths.append(len(b))
        pool.extend(b)
    while len(pool) % 4 != 0:
        pool.append(0)

    word_freqs = [scaled_unigrams[w] for w in sorted_words]

    sorted_bigram_keys = sorted(
        bigram_counts.keys(), key=lambda p: (word_id[p[0]], word_id[p[1]])
    )
    bigram_first_ids = [word_id[p[0]] for p in sorted_bigram_keys]
    bigram_second_ids = [word_id[p[1]] for p in sorted_bigram_keys]
    bigram_freqs = [scaled_bigrams[p] for p in sorted_bigram_keys]

    total_unigram_tokens = sum(word_freqs)
    unigram_count = len(sorted_words)
    bigram_count = len(sorted_bigram_keys)

    with open(out_path, 'wb') as f:
        header = struct.pack(
            '<IIIIIQI',
            MAGIC, VERSION, unigram_count, bigram_count, len(pool),
            total_unigram_tokens, 0,
        )
        assert len(header) == 32
        f.write(header)
        f.write(bytes(pool))
        for off in word_offsets:
            f.write(struct.pack('<I', off))
        for length in word_lengths:
            f.write(struct.pack('<B', length))
        pad = (-unigram_count) % 4
        f.write(b'\x00' * pad)
        for freq in word_freqs:
            f.write(struct.pack('<I', freq))
        for wid in bigram_first_ids:
            f.write(struct.pack('<I', wid))
        for wid in bigram_second_ids:
            f.write(struct.pack('<I', wid))
        for freq in bigram_freqs:
            f.write(struct.pack('<I', freq))

    print(
        f'{out_path}: {unigram_count} unigrams (scale divisor={uni_divisor}), '
        f'{bigram_count} bigrams (scale divisor={bi_divisor}, dropped={dropped_bigrams}), '
        f'totalUnigramTokens={total_unigram_tokens}'
    )


def main():
    parser = argparse.ArgumentParser(description='Build a .lex frequency binary.')
    parser.add_argument('--unigrams', required=True, help='word-frequency source file')
    parser.add_argument('--bigrams', required=True, help='bigram-frequency source file')
    parser.add_argument('--out', required=True, help='output .lex path')
    args = parser.parse_args()
    build(args.unigrams, args.bigrams, args.out)


if __name__ == '__main__':
    main()
