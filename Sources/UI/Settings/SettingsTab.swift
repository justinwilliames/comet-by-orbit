import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case general = "General"
    case voiceCommands = "Voice Commands"
    case providers = "Providers"
    case prompts = "Prompts"
    case activity = "Activity"
    case requests = "Requests"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .setup:
            return "sparkles"
        case .general:
            return "slider.horizontal.3"
        case .voiceCommands:
            return "mic.and.signal.meter.fill"
        case .providers:
            return "key.fill"
        case .prompts:
            return "text.bubble.fill"
        case .activity:
            return "clock.arrow.circlepath"
        case .requests:
            return "network"
        }
    }

    var subtitle: String {
        switch self {
        case .setup:
            return "Get ready to dictate"
        case .general:
            return "Shortcuts, permissions, and behavior"
        case .voiceCommands:
            return "Hands-free phrases when armed"
        case .providers:
            return "Speech and cleanup services"
        case .prompts:
            return "Cleanup instructions and vocabulary"
        case .activity:
            return "Recent transcripts and pipeline output"
        case .requests:
            return "Provider API calls, errors, and timings"
        }
    }
}
