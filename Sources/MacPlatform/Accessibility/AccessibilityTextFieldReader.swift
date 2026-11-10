import ApplicationServices
import DictionaryKit
import Foundation

/// The Accessibility reference inside a `TextFieldTarget` made by `AccessibilityTextFieldReader`. Only that reader
/// makes these and reads them back.
struct AXElementHandle: @unchecked Sendable {
    // Safe: an AXUIElement is an immutable reference to an element in another process, and the Accessibility API
    // may be called with it from any thread. Nothing here mutates it; every call goes through the system's own
    // messaging, which the reader bounds with a timeout.
    let element: AXUIElement
}

/// Reads the focused text field of the app in front through Accessibility, for the insertion context and the
/// correction watch (ARCHITECTURE.md, section 6, "Accessibility reads"). It reads another app's text, so every
/// call is bounded: each element it uses gets a short messaging timeout, only the role, subrole, focus, character
/// count, selection and `AXStringForRange` attributes are read, and the whole `AXValue` is never requested, not
/// even when range reads are unsupported. A field that is secure, or whose security cannot be established, reads
/// as nothing. Nothing read is logged.
///
/// The calls block until the other app answers or the timeout passes, so callers run them on a queue of their own,
/// never on the main thread or the cooperative pool.
public final class AccessibilityTextFieldReader: TextFieldReading {
    /// How long one Accessibility message may wait for the other app before it fails.
    public static let messagingTimeout: Float = 0.25

    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// A reader for the app in front. It holds no state, so one instance may serve every caller.
    public init() {}

    /// Whether Sorello is trusted for Accessibility. Only reads the state; never prompts.
    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    public func captureFocusedTextField() -> TextFieldTarget? {
        guard let (pid, element) = focusedElement(), pid != ownPID, isEditableText(element) else { return nil }
        return TextFieldTarget(pid: pid, element: AXElementHandle(element: element))
    }

    public func check(_ target: TextFieldTarget) -> TextFieldCheck {
        guard let element = axElement(target) else { return .failed }
        guard let (pid, focused) = focusedElement() else { return .failed }
        guard pid == target.pid, CFEqual(focused, element) else { return .focusChanged }
        guard let subrole = stringAttribute(element, kAXSubroleAttribute) else {
            // A missing subrole is normal; an error establishing it is not.
            return subroleIsAbsent(element) ? .ok : .failed
        }
        return subrole == kAXSecureTextFieldSubrole ? .secure : .ok
    }

    public func characterCount(_ target: TextFieldTarget) -> Int? {
        guard let element = axElement(target),
              let value = copyAttribute(element, kAXNumberOfCharactersAttribute),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var count = 0
        // The type was checked above, so the downcast cannot fail.
        guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .cfIndexType, &count), count >= 0 else {
            return nil
        }
        return count
    }

    public func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? {
        guard let element = axElement(target),
              let value = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return TextFieldRange(location: range.location, length: range.length)
    }

    public func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? {
        guard let element = axElement(target), range.location >= 0, range.length >= 0 else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    // MARK: - Helpers

    /// The element inside a target this reader made, with the timeout set. Any other payload gives nil, so a target
    /// from somewhere else fails its reads instead of crashing.
    private func axElement(_ target: TextFieldTarget) -> AXUIElement? {
        guard let handle = target.element as? AXElementHandle else { return nil }
        AXUIElementSetMessagingTimeout(handle.element, Self.messagingTimeout)
        return handle.element
    }

    /// The system-wide focused element and its process, with timeouts set on every object used. The focused
    /// application must own the element.
    private func focusedElement() -> (Int32, AXUIElement)? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        guard let focusedApp = copyAttribute(systemWide, kAXFocusedApplicationAttribute),
              CFGetTypeID(focusedApp) == AXUIElementGetTypeID(),
              let focused = copyAttribute(systemWide, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let app = unsafeDowncast(focusedApp, to: AXUIElement.self)
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var appPID: pid_t = 0, elementPID: pid_t = 0
        guard AXUIElementGetPid(app, &appPID) == .success, AXUIElementGetPid(element, &elementPID) == .success,
              appPID == elementPID, appPID > 0 else { return nil }
        return (appPID, element)
    }

    /// An editable text area, text field or combo box that is not secure.
    private func isEditableText(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(element, kAXRoleAttribute), Self.textRoles.contains(role) else { return false }
        if let subrole = stringAttribute(element, kAXSubroleAttribute) {
            guard subrole != kAXSecureTextFieldSubrole else { return false }
        } else if !subroleIsAbsent(element) {
            return false
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func subroleIsAbsent(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        return error == .noValue || error == .attributeUnsupported
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: CFString.self) as String
    }
}
