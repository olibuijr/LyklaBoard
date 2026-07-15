import Foundation

/// Per-word language attribution for learned counts.
///
/// This is attribution metadata only. Storage is SURFACE FORMS — the hint
/// says "this commit happened while the engine believed the lane was
/// Icelandic/English", it never triggers any lemma-level merging (see
/// `LemmaBoostProviding` for the wave-2 seam).
public enum LanguageHint: String, Codable, CaseIterable, Sendable {
    case icelandic = "is"
    case english = "en"
    case unknown = "un"
}

/// A single learning event, as emitted by the keyboard extension.
///
/// ## Privacy invariants (HARD — see also `LearningPrivacy`)
///
/// 1. **Single words / word pairs only. NEVER running text.** The largest
///    unit of language any event may carry is one word plus its immediate
///    predecessor (`wordCommitted.previousWord`). No sentence, no context
///    window, no n>2 grams.
/// 2. **No timestamps finer than a coarse day bucket.** Events are stamped
///    with a UTC day number (`DayBucket`) at append time — never a
///    time-of-day, never a monotonic clock.
/// 3. **Secure / URL / email / password fields must never be logged.** The
///    package cannot see the host text field, so this is enforced by the
///    caller (the extension's input pipeline). Call
///    `LearningPrivacy.assertLoggableFieldContext(...)` at the call boundary;
///    it traps in debug builds and invokes the installable
///    `violationHandler` in release builds.
public enum LearningEvent: Equatable, Sendable {
    /// A word was committed to the document (space/delimiter/return), with
    /// the immediately preceding committed word if one exists, and the
    /// engine's language-lane belief at commit time.
    case wordCommitted(word: String, previousWord: String?, languageHint: LanguageHint)
    /// The user tapped a suggestion-bar candidate: `typed` is the raw token,
    /// `accepted` is the candidate that was committed instead.
    case suggestionAccepted(typed: String, accepted: String)
    /// The user reverted an applied autocorrection: `original` is what they
    /// actually typed (and got back), `applied` is the correction they
    /// rejected.
    case correctionReverted(original: String, applied: String)
    /// The user tapped the quoted verbatim slot — the strongest explicit
    /// "this is a real word" signal (learns immediately, no day threshold).
    case wordTapped(word: String)
    /// One touch sample for the per-key adaptive touch model: `dx`/`dy` are
    /// offsets from the resolved key's center, normalized to key units
    /// (1.0 = one key width/height). Only confirmed text should train this
    /// model — the caller must emit samples for committed words only.
    case touchSample(keyChar: Character, dx: Double, dy: Double)
}

/// An event as read back from the log: the event plus the coarse UTC day
/// bucket it was appended on (the only temporal information ever stored).
public struct LoggedEvent: Equatable, Sendable {
    /// UTC day bucket (days since 1970-01-01, `DayBucket`).
    public let day: Int32
    public let event: LearningEvent

    public init(day: Int32, event: LearningEvent) {
        self.day = day
        self.event = event
    }
}

/// Coarse day bucketing — the maximum temporal resolution this package is
/// allowed to persist (privacy invariant #2 on `LearningEvent`).
public enum DayBucket {
    /// Whole days since the Unix epoch, UTC. Deliberately not calendar-aware:
    /// the only property compaction needs is "distinct buckets ≈ distinct
    /// days", and a fixed 86 400 s bucket has no time-zone leakage.
    public static func bucket(for date: Date) -> Int32 {
        Int32(floor(date.timeIntervalSince1970 / 86_400))
    }

    public static func current() -> Int32 {
        bucket(for: Date())
    }
}
