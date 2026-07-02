import CoreGraphics
import Foundation

/// A single keystroke a voice command injects into the focused app.
struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// One voice command available while the wake word is armed and idle. This is
/// the single source of truth — the wake-word matcher and the in-app
/// "Voice Commands" reference page both read from `VoiceCommands.keystroke`, so
/// they can never drift apart.
struct VoiceCommand: Identifiable {
    let id: String
    let title: String            // e.g. "Select all"
    let keystrokeLabel: String   // e.g. "⌘A"
    let phrases: [String]        // normalized (lowercase) match targets
    let stroke: KeyStroke
    let isDestructive: Bool

    init(
        id: String,
        title: String,
        keystrokeLabel: String,
        phrases: [String],
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        isDestructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.keystrokeLabel = keystrokeLabel
        self.phrases = phrases
        self.stroke = KeyStroke(keyCode: keyCode, flags: flags)
        self.isDestructive = isDestructive
    }
}

enum VoiceCommands {
    // macOS virtual key codes used below:
    // A=0x00 Z=0x06 C=0x08 V=0x09 Return=0x24 Tab=0x30 Delete=0x33 Escape=0x35.

    /// Keystroke commands recognized while ARMED + IDLE (not mid-recording).
    /// Ordered as they appear on the reference page.
    static let keystroke: [VoiceCommand] = [
        VoiceCommand(
            id: "send", title: "Send / press Return", keystrokeLabel: "⏎",
            phrases: ["press return", "press enter", "hit return", "hit enter", "send message", "send dictation"],
            keyCode: 0x24
        ),
        VoiceCommand(
            id: "newline", title: "New line (no send)", keystrokeLabel: "⇧⏎",
            phrases: ["new line", "line break", "soft return"],
            keyCode: 0x24, flags: .maskShift
        ),
        VoiceCommand(
            id: "selectAll", title: "Select all", keystrokeLabel: "⌘A",
            phrases: ["select all"],
            keyCode: 0x00, flags: .maskCommand
        ),
        VoiceCommand(
            id: "copy", title: "Copy", keystrokeLabel: "⌘C",
            phrases: ["copy that", "copy all", "copy text"],
            keyCode: 0x08, flags: .maskCommand
        ),
        VoiceCommand(
            id: "paste", title: "Paste", keystrokeLabel: "⌘V",
            phrases: ["paste that", "paste text"],
            keyCode: 0x09, flags: .maskCommand
        ),
        VoiceCommand(
            id: "undo", title: "Undo", keystrokeLabel: "⌘Z",
            phrases: ["undo that", "undo last", "undo typing"],
            keyCode: 0x06, flags: .maskCommand
        ),
        VoiceCommand(
            id: "redo", title: "Redo", keystrokeLabel: "⌘⇧Z",
            phrases: ["redo that", "redo last"],
            keyCode: 0x06, flags: [.maskCommand, .maskShift]
        ),
        VoiceCommand(
            id: "tab", title: "Tab / next field", keystrokeLabel: "⇥",
            phrases: ["press tab", "next field"],
            keyCode: 0x30
        ),
        VoiceCommand(
            id: "escape", title: "Escape", keystrokeLabel: "⎋",
            phrases: ["press escape", "escape that", "cancel field"],
            keyCode: 0x35
        ),
        VoiceCommand(
            id: "deleteWord", title: "Delete word", keystrokeLabel: "⌥⌫",
            phrases: ["delete word", "delete that"],
            keyCode: 0x33, flags: .maskAlternate, isDestructive: true
        ),
        VoiceCommand(
            id: "deleteLine", title: "Delete line", keystrokeLabel: "⌘⌫",
            phrases: ["delete line"],
            keyCode: 0x33, flags: .maskCommand, isDestructive: true
        ),
    ]

    // Display strings for the mode commands (handled specially by the listener).
    static let startDisplayPhrases = "“Start Comet” · “Hey Comet” · “Start Dictation” · “Hey Dictation”"
    static let stopDisplayPhrases = "“Stop Comet” · “End Comet” · “Stop Dictation” · “End Dictation”"
}
