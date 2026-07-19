package `is`.solberg.lyklabord.engine.learning

/** Privacy-invariant enforcement hook at event-log call boundaries. */
object LearningPrivacy {
    var violationHandler: (String) -> Unit = { message -> assert(false) { message } }

    fun assertLoggableFieldContext(isSecureTextEntry: Boolean, isSensitiveKeyboardType: Boolean) {
        if (isSecureTextEntry) violationHandler("PRIVACY VIOLATION: attempted to log learning events from a secure text field")
        if (isSensitiveKeyboardType) violationHandler("PRIVACY VIOLATION: attempted to log learning events from a URL/email/web-search field")
    }
}
