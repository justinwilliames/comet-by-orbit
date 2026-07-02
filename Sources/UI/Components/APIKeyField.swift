import SwiftUI

/// A secure text field for entering and storing API keys in the Keychain.
///
/// The editable `value` only ever holds what the user actually types — the
/// "a key is already saved" state is shown as status text, never as a
/// placeholder *inside* the value (which previously could be saved verbatim,
/// overwriting the real key with mask characters).
///
/// Reveal behaviour: tapping the eye when a key is stored loads the saved
/// value directly from the Keychain so the user can inspect it. Re-concealing
/// (or the trash action) clears that loaded value so it cannot be accidentally
/// re-saved unchanged.
struct APIKeyField: View {
    let label: String
    let key: KeychainKey
    let keychain: KeychainManager

    @State private var value: String = ""
    @State private var isSaved: Bool = false
    @State private var isRevealed: Bool = false
    @State private var hasStoredKey: Bool = false
    /// True while `value` was loaded from Keychain via the reveal button
    /// (as opposed to freshly typed by the user).
    @State private var isRevealedFromKeychain: Bool = false

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if hasStoredKey {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField(placeholder, text: $value)
                            .id("apikey-visible-\(key.rawValue)")
                    } else {
                        SecureField(placeholder, text: $value)
                            .id("apikey-secure-\(key.rawValue)")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

                // Eye / reveal button — loads from Keychain on reveal when field is empty
                Button {
                    if !isRevealed, hasStoredKey, value.isEmpty {
                        // Load saved key at reveal time only — never on appear
                        value = keychain.get(key) ?? ""
                        isRevealedFromKeychain = true
                    } else if isRevealed, isRevealedFromKeychain {
                        // Re-conceal: discard the loaded value so it can't be saved unchanged
                        value = ""
                        isRevealedFromKeychain = false
                    }
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                Button(isSaved ? "Saved" : "Save") {
                    let trimmed = trimmedValue
                    guard !trimmed.isEmpty else { return }
                    keychain.set(self.key, value: trimmed)
                    hasStoredKey = true
                    isRevealedFromKeychain = false
                    value = ""
                    isRevealed = false
                    withAnimation { isSaved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isSaved = false
                    }
                }
                // Disable when empty, or when the revealed-from-keychain value is unchanged
                .disabled(
                    trimmedValue.isEmpty ||
                    (isRevealedFromKeychain && trimmedValue == (keychain.get(key) ?? ""))
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if hasStoredKey {
                    Button {
                        keychain.delete(key)
                        hasStoredKey = false
                        isRevealedFromKeychain = false
                        value = ""
                        isRevealed = false
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            // Never seed `value` with a mask — leave it empty so nothing but a
            // freshly typed key can ever be written to the Keychain.
            hasStoredKey = keychain.has(key)
        }
        // Re-read stored state whenever any key changes (fixes stale badge across
        // duplicate APIKeyField instances pointing at the same KeychainKey).
        .onReceive(NotificationCenter.default.publisher(for: KeychainManager.apiKeysDidChange)) { note in
            if note.object as? String == key.rawValue {
                hasStoredKey = keychain.has(key)
                // If the key was just deleted by another instance, clear any revealed state
                if !hasStoredKey {
                    isRevealedFromKeychain = false
                    value = ""
                    isRevealed = false
                }
            }
        }
    }

    private var placeholder: String {
        hasStoredKey ? "Key saved — type a new one to replace" : "Enter key…"
    }
}
