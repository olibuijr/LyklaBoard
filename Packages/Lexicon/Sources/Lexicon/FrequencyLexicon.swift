import Foundation

public enum FrequencyLexiconError: Error, CustomStringConvertible {
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidMagic(let m):
            return "Invalid binary format: expected magic 0x4c584331, got 0x\(String(m, radix: 16))"
        case .unsupportedVersion(let v):
            return "Unsupported version: \(v)"
        case .truncated(let expected, let actual):
            return "Truncated binary: need \(expected) bytes, file has \(actual)"
        }
    }
}

/// Binary-format unigram/bigram frequency table.
///
/// Reads the `.lex` artifact produced by `scripts/build-lexicon.py`. See
/// `Packages/Lexicon/FORMAT.md` for the full byte layout.
///
/// Memory strategy: mirrors `LemmaCore.BinaryLemmatizer` — the file is
/// memory-mapped (`Data(contentsOf:options:.alwaysMapped)`) and *never*
/// parsed into Swift collections. The initializer only reads the 32-byte
/// header and computes section offsets; every lookup does lazy, offset-based
/// reads straight out of the mapped buffer via binary search. File-backed
/// clean pages don't count against the iOS keyboard-extension jetsam limit.
///
/// String comparison is byte-exact UTF-8 (code-point order), matching the
/// Python builder's `sorted()` — never Swift `String ==`/`<`, which apply
/// Unicode canonical equivalence that the builder's raw-byte sort does not.
public final class FrequencyLexicon: Lexicon {

    private static let magic: UInt32 = 0x4C58_4331  // "LXC1" little-endian

    /// Range scans for `completions(of:)` stop after this many candidate
    /// words even if the prefix's true range is larger (only reachable with
    /// very short prefixes on a large table). See FORMAT.md.
    private static let maxCompletionScan = 20_000

    private let data: Data

    public let version: Int
    public let unigramCount: Int
    public let bigramCount: Int
    public let totalUnigramTokens: UInt64

    // Byte offsets of each section from the start of the file.
    private let stringPoolOffset: Int
    private let stringPoolSize: Int
    private let wordOffsetsOffset: Int
    private let wordLengthsOffset: Int
    private let wordFreqsOffset: Int
    private let bigramFirstIdsOffset: Int
    private let bigramSecondIdsOffset: Int
    private let bigramFreqsOffset: Int

    /// Memory-map a `.lex` file. Preferred entry point on iOS/macOS.
    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data)
    }

    /// Wrap an already-loaded buffer.
    public init(data: Data) throws {
        self.data = data

        guard data.count >= 32 else {
            throw FrequencyLexiconError.truncated(expected: 32, actual: data.count)
        }

        func u32(_ byteOffset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
            }
        }
        func u64(_ byteOffset: Int) -> UInt64 {
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt64.self).littleEndian
            }
        }

        let magic = u32(0)
        guard magic == Self.magic else {
            throw FrequencyLexiconError.invalidMagic(magic)
        }

        let versionRaw = u32(4)
        guard versionRaw == 1 else {
            throw FrequencyLexiconError.unsupportedVersion(versionRaw)
        }
        self.version = Int(versionRaw)

        self.unigramCount = Int(u32(8))
        self.bigramCount = Int(u32(12))
        self.stringPoolSize = Int(u32(16))
        self.totalUnigramTokens = u64(20)
        // u32 at 28 is reserved

        // Section layout — must match build-lexicon.py.
        var offset = 32

        stringPoolOffset = offset
        offset += stringPoolSize  // writer pads the pool itself to 4 bytes

        wordOffsetsOffset = offset
        offset += unigramCount * 4

        wordLengthsOffset = offset
        offset += unigramCount
        offset = (offset + 3) & ~3

        wordFreqsOffset = offset
        offset += unigramCount * 4

        bigramFirstIdsOffset = offset
        offset += bigramCount * 4

        bigramSecondIdsOffset = offset
        offset += bigramCount * 4

        bigramFreqsOffset = offset
        offset += bigramCount * 4

        guard data.count >= offset else {
            throw FrequencyLexiconError.truncated(expected: offset, actual: data.count)
        }
    }

    // MARK: - Public API

    public func frequency(of word: String) -> UInt32? {
        let key = normalizedKey(word)
        guard !key.isEmpty else { return nil }
        return withBuffer { buf in
            guard let idx = findWord(key, in: buf) else { return nil }
            return readU32(buf, at: wordFreqsOffset + idx * 4)
        }
    }

    public func bigramFrequency(_ first: String, _ second: String) -> UInt32? {
        let k1 = normalizedKey(first)
        let k2 = normalizedKey(second)
        guard !k1.isEmpty, !k2.isEmpty else { return nil }
        return withBuffer { buf in
            guard let id1 = findWord(k1, in: buf), let id2 = findWord(k2, in: buf) else { return nil }
            guard let idx = findBigram(UInt32(id1), UInt32(id2), in: buf) else { return nil }
            return readU32(buf, at: bigramFreqsOffset + idx * 4)
        }
    }

    public func completions(of prefix: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        let key = normalizedKey(prefix)
        guard !key.isEmpty else { return [] }

        return withBuffer { buf in
            let lo = lowerBound(key, in: buf)
            guard lo < unigramCount else { return [] }

            let hi: Int
            if let succ = successor(key) {
                hi = lowerBound(succ, in: buf)
            } else {
                hi = unigramCount
            }
            guard hi > lo else { return [] }

            let scanEnd = min(hi, lo + Self.maxCompletionScan)
            var candidates: [(word: String, frequency: UInt32)] = []
            candidates.reserveCapacity(scanEnd - lo)
            for i in lo..<scanEnd {
                let freq = readU32(buf, at: wordFreqsOffset + i * 4)
                candidates.append((wordString(at: i, in: buf), freq))
            }
            candidates.sort {
                $0.frequency != $1.frequency ? $0.frequency > $1.frequency : $0.word < $1.word
            }
            return Array(candidates.prefix(limit))
        }
    }

    /// Raw buffer size in bytes (approximate *virtual* footprint; resident
    /// dirty memory stays near zero because the buffer is file-backed).
    public var bufferSize: Int { data.count }

    // MARK: - Internals (all operate on the mapped raw buffer)

    /// Lowercase + NFC-normalize a query word/prefix into UTF-8 bytes, the
    /// same normalization the builder applies to stored words.
    @inline(__always)
    private func normalizedKey(_ s: String) -> [UInt8] {
        Array(s.lowercased().precomposedStringWithCanonicalMapping.utf8)
    }

    @inline(__always)
    private func withBuffer<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        data.withUnsafeBytes(body)
    }

    @inline(__always)
    private func readU32(_ buf: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt32 {
        buf.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
    }

    @inline(__always)
    private func readU8(_ buf: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt8 {
        buf[byteOffset]
    }

    @inline(__always)
    private func poolString(_ buf: UnsafeRawBufferPointer, offset: Int, length: Int) -> String {
        let start = stringPoolOffset + offset
        let bytes = UnsafeRawBufferPointer(rebasing: buf[start..<start + length])
        return String(decoding: bytes, as: UTF8.self)
    }

    @inline(__always)
    private func wordString(at index: Int, in buf: UnsafeRawBufferPointer) -> String {
        let offset = Int(readU32(buf, at: wordOffsetsOffset + index * 4))
        let length = Int(readU8(buf, at: wordLengthsOffset + index))
        return poolString(buf, offset: offset, length: length)
    }

    /// Lexicographic comparison of `key` against a pool string, by raw UTF-8
    /// bytes (== Unicode code-point order == the Python writer's sort
    /// order). Returns -1/0/1 like `key.compare(word)`.
    @inline(__always)
    private func compareKey(
        _ key: [UInt8], poolOffset: Int, poolLength: Int, in buf: UnsafeRawBufferPointer
    ) -> Int {
        let base = stringPoolOffset + poolOffset
        let n = min(key.count, poolLength)
        var i = 0
        while i < n {
            let a = key[i]
            let b = buf[base + i]
            if a != b { return a < b ? -1 : 1 }
            i += 1
        }
        if key.count == poolLength { return 0 }
        return key.count < poolLength ? -1 : 1
    }

    @inline(__always)
    private func compareKeyAt(_ key: [UInt8], index: Int, in buf: UnsafeRawBufferPointer) -> Int {
        let offset = Int(readU32(buf, at: wordOffsetsOffset + index * 4))
        let length = Int(readU8(buf, at: wordLengthsOffset + index))
        return compareKey(key, poolOffset: offset, poolLength: length, in: buf)
    }

    /// Exact-match binary search over the alphabetically sorted word index.
    private func findWord(_ key: [UInt8], in buf: UnsafeRawBufferPointer) -> Int? {
        var left = 0
        var right = unigramCount - 1
        while left <= right {
            let mid = (left + right) >> 1
            switch compareKeyAt(key, index: mid, in: buf) {
            case 0: return mid
            case let c where c > 0: left = mid + 1
            default: right = mid - 1
            }
        }
        return nil
    }

    /// Leftmost index `i` such that `word[i] >= key` (standard lower_bound).
    /// Used by `completions(of:)` to find the start of a prefix's range.
    private func lowerBound(_ key: [UInt8], in buf: UnsafeRawBufferPointer) -> Int {
        var lo = 0
        var hi = unigramCount
        while lo < hi {
            let mid = (lo + hi) >> 1
            // compareKey(key, word) <= 0  <=>  key <= word  <=>  word >= key
            if compareKeyAt(key, index: mid, in: buf) <= 0 {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }

    /// Lexicographic successor of a byte string: the smallest byte string
    /// strictly greater than every string that has `bytes` as a prefix.
    /// Returns nil if `bytes` is all-0xFF (no successor exists — treat the
    /// range as extending to the end of the table).
    private func successor(_ bytes: [UInt8]) -> [UInt8]? {
        var result = bytes
        while let last = result.last {
            if last == 0xFF {
                result.removeLast()
            } else {
                result[result.count - 1] = last + 1
                return result
            }
        }
        return nil
    }

    /// Binary search over bigrams sorted by (firstWordId, secondWordId).
    private func findBigram(_ id1: UInt32, _ id2: UInt32, in buf: UnsafeRawBufferPointer) -> Int? {
        var left = 0
        var right = bigramCount - 1
        while left <= right {
            let mid = (left + right) >> 1
            let f = readU32(buf, at: bigramFirstIdsOffset + mid * 4)
            let s = readU32(buf, at: bigramSecondIdsOffset + mid * 4)
            if f == id1 && s == id2 { return mid }
            if f < id1 || (f == id1 && s < id2) {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        return nil
    }
}
