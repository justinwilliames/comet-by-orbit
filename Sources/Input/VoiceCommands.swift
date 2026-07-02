import CoreGraphics
import Foundation

/// A single keystroke a voice command injects into the focused app.
struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// One voice command available while the wake word is armed and idle.
///
/// Every command must be spoken with the wake keyword first ("Comet …") so
/// ordinary dictated words can never trigger one — "select all" does nothing,
/// but "Comet select all" fires ⌘A. `phrases` is the full set of normalized
/// match targets (every keyword × every action wording); `actions` holds the
/// keyword-less wordings for display.
struct VoiceCommand: Identifiable {
    let id: String
    let title: String            // e.g. "Select all"
    let keystrokeLabel: String   // e.g. "⌘A"
    let actions: [String]        // keyword-less wordings, e.g. ["select all"]
    let stroke: KeyStroke
    let isDestructive: Bool

    init(
        id: String,
        title: String,
        keystrokeLabel: String,
        actions: [String],
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        isDestructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.keystrokeLabel = keystrokeLabel
        self.actions = actions
        self.stroke = KeyStroke(keyCode: keyCode, flags: flags)
        self.isDestructive = isDestructive
    }

    /// Full normalized match targets: every keyword + every action wording.
    var phrases: [String] {
        VoiceCommands.keywords.flatMap { keyword in actions.map { "\(keyword) \($0)" } }
    }

    /// Canonical spoken example, e.g. "Comet select all".
    var example: String { "Comet \(actions.first ?? "")" }
}

enum VoiceCommands {
    /// The wake keyword that must precede EVERY command — "Comet start
    /// dictation", "Comet stop dictation", "Comet new line". Ordinary speech
    /// never starts with it, so nothing fires by accident. Includes common
    /// mishears of "comet".
    static let keywords = ["comet", "comets", "komet", "comment", "comments", "commit"]

    /// Words fed to the transcriber as a bias hint, so it expects the command
    /// vocabulary — improves recognition of dropped/soft consonants (accents).
    static let biasVocabulary = [
        "Comet", "start dictation", "stop dictation", "new line", "select all",
        "copy", "paste", "undo", "redo", "tab", "escape", "send", "return",
        "press enter", "delete word", "delete line",
    ]

    /// Actions (keyword-less) that START recording, e.g. "Comet start".
    /// Includes "star" — the recognizer commonly drops the 't' in "start".
    static let startActions = [
        "start", "start dictation", "start recording", "starting",
        "star", "star dictation", "begin", "begin dictation", "go",
    ]
    /// Actions that STOP recording, e.g. "Comet stop".
    static let stopActions = ["stop", "stop dictation", "stop recording", "end", "end dictation", "finish"]

    /// Full normalized match targets for start / stop (keyword × action).
    static let startPhrases = prefixed(startActions)
    static let stopPhrases = prefixed(stopActions)

    /// Prefix each action with every keyword.
    static func prefixed(_ actions: [String]) -> [String] {
        keywords.flatMap { keyword in actions.map { "\(keyword) \($0)" } }
    }

    // macOS virtual key codes used below:
    // A=0x00 Z=0x06 C=0x08 V=0x09 Return=0x24 Tab=0x30 Delete=0x33 Escape=0x35.

    /// Keystroke commands recognized while ARMED + IDLE (not mid-recording).
    /// Spoken as "Comet <action>". Ordered as they appear on the reference page.
    static let keystroke: [VoiceCommand] = [
        VoiceCommand(
            id: "send", title: "Send / press Return", keystrokeLabel: "⏎",
            actions: ["send", "return", "enter", "press return", "press enter"],
            keyCode: 0x24
        ),
        VoiceCommand(
            id: "newline", title: "New line (no send)", keystrokeLabel: "⇧⏎",
            actions: ["new line", "next line", "line break", "soft return"],
            keyCode: 0x24, flags: .maskShift
        ),
        VoiceCommand(
            id: "selectAll", title: "Select all", keystrokeLabel: "⌘A",
            actions: ["select all"],
            keyCode: 0x00, flags: .maskCommand
        ),
        VoiceCommand(
            id: "copy", title: "Copy", keystrokeLabel: "⌘C",
            actions: ["copy", "copy that", "copy all"],
            keyCode: 0x08, flags: .maskCommand
        ),
        VoiceCommand(
            id: "paste", title: "Paste", keystrokeLabel: "⌘V",
            actions: ["paste", "paste that"],
            keyCode: 0x09, flags: .maskCommand
        ),
        VoiceCommand(
            id: "undo", title: "Undo", keystrokeLabel: "⌘Z",
            actions: ["undo", "undo that"],
            keyCode: 0x06, flags: .maskCommand
        ),
        VoiceCommand(
            id: "redo", title: "Redo", keystrokeLabel: "⌘⇧Z",
            actions: ["redo", "redo that"],
            keyCode: 0x06, flags: [.maskCommand, .maskShift]
        ),
        VoiceCommand(
            id: "tab", title: "Tab / next field", keystrokeLabel: "⇥",
            actions: ["tab", "next field"],
            keyCode: 0x30
        ),
        VoiceCommand(
            id: "escape", title: "Escape", keystrokeLabel: "⎋",
            actions: ["escape", "cancel"],
            keyCode: 0x35
        ),
        VoiceCommand(
            id: "deleteWord", title: "Delete word", keystrokeLabel: "⌥⌫",
            actions: ["delete word"],
            keyCode: 0x33, flags: .maskAlternate, isDestructive: true
        ),
        VoiceCommand(
            id: "deleteLine", title: "Delete line", keystrokeLabel: "⌘⌫",
            actions: ["delete line"],
            keyCode: 0x33, flags: .maskCommand, isDestructive: true
        ),
    ]

    // Display strings for the mode commands (handled specially by the listener).
    static let startDisplayPhrases = "“Comet start dictation” · “Comet start” · “Comet begin”"
    static let stopDisplayPhrases = "“Comet stop dictation” · “Comet stop” · “Comet end”"
}
