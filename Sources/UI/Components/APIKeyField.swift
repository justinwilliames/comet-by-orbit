import SwiftUI

/// A secure text field for entering and storing API keys in the Keychain.
///
/// The editable `value` only ever holds what the user actually types — the
/// "a key is already saved" state is shown as status text, never as a
/// placeholder *inside* the value (which previously could be saved verbatim,
/// overwriting the real key with mask characters).
struct APIKeyField: View {
    let label: String
    let key: KeychainKey
    let keychain: KeychainManager

    @State private var value: String = ""
    @State private var isSaved: Bool = false
    @State private var isRevealed: Bool = false
    @State private var hasStoredKey: Bool = false

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
                    } else {
                        SecureField(placeholder, text: $value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                Button(isSaved ? "Saved" : "Save") {
                    let key = trimmedValue
                    guard !key.isEmpty else { return }
                    keychain.set(self.key, value: key)
                    hasStoredKey = true
                    value = ""
                    withAnimation { isSaved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isSaved = false
                    }
                }
                .disabled(trimmedValue.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if hasStoredKey {
                    Button {
                        keychain.delete(key)
                        hasStoredKey = false
                        value = ""
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
    }

    private var placeholder: String {
        hasStoredKey ? "Key saved — type a new one to replace" : "Enter key…"
    }
}
