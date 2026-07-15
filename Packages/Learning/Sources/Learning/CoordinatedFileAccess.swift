import Foundation

/// Thin `NSFileCoordinator` wrappers for App Group files shared between the
/// keyboard extension (event-log writer) and the containing app (compactor,
/// model owner). Both sides MUST route every `EventLog` / `PersonalModel`
/// disk touch through these so a compaction rewrite can never interleave
/// with an append.
///
/// Usage expectations at the call boundary:
///
/// - **Extension (writer)**: batch events in memory; flush inside ONE short
///   `coordinateWrite` block at word boundaries / `viewWillDisappear` — never
///   per keystroke, and never hold the coordination across an await. Apple
///   documents that app extensions holding file coordination while being
///   suspended can deadlock the host — keep blocks synchronous and tiny, and
///   treat a coordination failure as "drop this batch" (learning data is
///   lossy-tolerant by design).
/// - **App (compactor)**: run read + merge + model-save + log-truncate inside
///   ONE `coordinateWrite` block on the log URL (the model file has a single
///   owner — the app — and only needs coordination if the extension ever
///   reads it directly; today the extension gets model data via its own
///   loaded copy, so plain atomic writes suffice there).
/// - Never cache file descriptors or `Data` across coordination blocks.
public enum CoordinatedFileAccess {
    /// Coordinated read. `accessor` receives the URL to actually read from
    /// (which may differ from `url` while another process moves the file).
    public static func coordinateRead<T>(
        at url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        byAccessor accessor: (URL) throws -> T
    ) throws -> T {
        try coordinate(url: url, isWrite: false, readOptions: options, writeOptions: [], accessor: accessor)
    }

    /// Coordinated write (also correct for read-modify-write sequences like
    /// compaction: read log → merge → truncate).
    public static func coordinateWrite<T>(
        at url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        byAccessor accessor: (URL) throws -> T
    ) throws -> T {
        try coordinate(url: url, isWrite: true, readOptions: [], writeOptions: options, accessor: accessor)
    }

    private static func coordinate<T>(
        url: URL,
        isWrite: Bool,
        readOptions: NSFileCoordinator.ReadingOptions,
        writeOptions: NSFileCoordinator.WritingOptions,
        accessor: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let block: (URL) -> Void = { actualURL in
            result = Result { try accessor(actualURL) }
        }
        if isWrite {
            coordinator.coordinate(writingItemAt: url, options: writeOptions, error: &coordinationError, byAccessor: block)
        } else {
            coordinator.coordinate(readingItemAt: url, options: readOptions, error: &coordinationError, byAccessor: block)
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw EventLogError.ioError("file coordination completed without invoking the accessor")
        }
        return try result.get()
    }
}
