import Carbon.HIToolbox
import Foundation

/// The virtual key that pastes in the current keyboard layout: the key that types "v" while Command is held. On
/// Dvorak that is the key labelled period, on "Dvorak - QWERTY ⌘" it is the QWERTY V key, and a layout that types no
/// "v" at all (Russian, Greek) pastes with the key the system's ASCII-capable layout would use.
public enum PasteKey {
    /// The paste key for the layouts in use now, or the ANSI V key when none of them types "v" under Command.
    ///
    /// Text Input Sources may only be asked on the main thread.
    @MainActor
    public static func current() -> UInt16 {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()]
        for source in sources {
            guard let layout = source,
                  let key = find(in: { code in characterWithCommand(code, layout: layout) }) else { continue }
            return key
        }
        return KeyCode.ansiV
    }

    /// The first virtual key, the ANSI V key first and then in code order, for which `character` gives "v". Nil when
    /// none does.
    public static func find(in character: (UInt16) -> String?) -> UInt16? {
        let codes = [KeyCode.ansiV] + (0..<128).map(UInt16.init).filter { $0 != KeyCode.ansiV }
        return codes.first { character($0) == "v" }
    }

    /// What `code` types with Command held in `layout`, ignoring dead keys.
    private static func characterWithCommand(_ code: UInt16, layout source: TISInputSource) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        guard data.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
