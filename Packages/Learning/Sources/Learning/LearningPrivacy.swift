import Foundation

/// Privacy-invariant enforcement hooks for the learning pipeline.
///
/// The invariants themselves are documented on `LearningEvent`. This type
/// gives callers a single choke point to assert the one invariant the
/// package cannot verify from inside: **content from secure, URL, email,
/// web-search or password fields must never reach `EventLog.append`.**
///
/// Expected call-site shape in the keyboard extension:
///
/// ```swift
/// LearningPrivacy.assertLoggableFieldContext(
///     isSecureTextEntry: proxy.isSecureTextEntry,
///     isSensitiveKeyboardType: keyboardType.isURLEmailOrWebSearch)
/// guard !proxy.isSecureTextEntry, !keyboardType.isURLEmailOrWebSearch else { return }
/// try eventLog.append(...)
/// ```
///
/// The `guard` is the actual enforcement; the assertion exists so a missing
/// guard is caught loudly in debug builds and observable (via
/// `violationHandler`) in release builds instead of silently leaking.
public enum LearningPrivacy {
    /// Invoked whenever `assertLoggableFieldContext` detects a sensitive
    /// field context. Defaults to `assertionFailure` (traps in debug, no-op
    /// in release). The containing app / extension may install a handler
    /// that e.g. increments a local diagnostics counter. Never install a
    /// handler that transmits anything — that would defeat the point.
    public static var violationHandler: (String) -> Void = { message in
        assertionFailure(message)
    }

    /// Assert that the current text-field context is allowed to feed the
    /// learning log. Call this immediately before any `EventLog.append`.
    public static func assertLoggableFieldContext(
        isSecureTextEntry: Bool,
        isSensitiveKeyboardType: Bool
    ) {
        if isSecureTextEntry {
            violationHandler("PRIVACY VIOLATION: attempted to log learning events from a secure text field")
        }
        if isSensitiveKeyboardType {
            violationHandler("PRIVACY VIOLATION: attempted to log learning events from a URL/email/web-search field")
        }
    }
}
