import SwiftUI

/// "Where is this?" — said out loud, in the shop, standing in front of the thing.
///
/// The aisle is created by putting something in it. There is no earlier step
/// where you declare that aisle 16 exists; that inversion is the whole feature.
///
/// Nothing is written until Save is tapped. Any recogniser confuses "sixteen"
/// and "sixty" over a tannoy, and this app has already shipped a fix for one
/// hearing "Thank you for watching" in silence — so what it heard, and where that
/// lands, are both on screen before anything is saved.
struct AisleCaptureSheet: View {
    let itemName: String
    let store: HouseholdStore
    /// Hands back the resolved aisle. Saving is the caller's job.
    let onSave: (AisleUtterance.Resolution) -> Void

    @StateObject private var speech = AisleSpeechService()
    @State private var typed: String = ""
    @State private var isTyping = false
    @FocusState private var keyboardFocused: Bool

    @Environment(\.dismiss) private var dismiss

    /// What the user last said or typed, whichever is in play.
    private var spoken: String {
        isTyping ? typed : speech.transcript
    }

    private var resolution: AisleUtterance.Resolution? {
        let text = spoken.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return AisleUtterance.resolve(text, in: store.aisleLayout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if isTyping {
                keyboardField
            } else {
                microphone
            }

            if let resolution {
                outcome(resolution)
            } else {
                Text(promptText)
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.background.ignoresSafeArea())
        .task {
            // Straight to the keyboard when the phone cannot listen, rather than
            // showing a microphone that does nothing.
            if speech.isAvailable {
                await speech.start(hints: aisleHints)
            } else {
                startTyping()
            }
        }
        .onDisappear { speech.stop() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where is it?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            Text(itemName)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
            Text(store.name)
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.textSecondary)
        }
    }

    private var microphone: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.dillGreen)
                    .frame(width: 74, height: 74)
                    .shadow(color: DesignSystem.Colors.dillGreen.opacity(0.35), radius: 14)
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.background)
            }
            .opacity(speech.state == .listening ? 1 : 0.55)

            if case .unavailable(let why) = speech.state {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.warning)
                    .multilineTextAlignment(.center)
            } else if !spoken.isEmpty {
                Text("“\(spoken)”")
                    .font(.system(size: 17))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
            } else {
                Text(speech.state == .listening ? "Listening…" : "Starting…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var keyboardField: some View {
        TextField("Aisle 16, or Bakery", text: $typed)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($keyboardFocused)
            .font(.system(size: 17))
            .foregroundColor(DesignSystem.Colors.textPrimary)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .fill(DesignSystem.Colors.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private func outcome(_ resolution: AisleUtterance.Resolution) -> some View {
        switch resolution {
        case .existing(let aisle):
            outcomeRow(
                label: AisleNaming.displayName(for: aisle.id, in: store.aisleLayout),
                note: "Already an aisle here",
                tint: DesignSystem.Colors.dillGreen
            )
        case .new(let number, let name):
            outcomeRow(
                label: number.isEmpty ? name : "Aisle \(number)",
                note: "New — added to the end of your walk order",
                tint: DesignSystem.Colors.neonAmber
            )
        case .rejected(let reason):
            Text(reason)
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.warning)
        }
    }

    private func outcomeRow(label: String, note: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text("Saves to")
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Text(label)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(DesignSystem.Colors.background)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint))
            Text(note)
                .font(.system(size: 11))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(isTyping ? "Speak" : "Type") {
                if isTyping {
                    isTyping = false
                    typed = ""
                    Task { await speech.start(hints: aisleHints) }
                } else {
                    startTyping()
                }
            }
            .buttonStyle(CaptureButtonStyle(filled: false))
            .disabled(!isTyping && !speech.isAvailable)

            Button("Save") {
                if let resolution, case .rejected = resolution {} else if let resolution {
                    speech.stop()
                    onSave(resolution)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            }
            .buttonStyle(CaptureButtonStyle(filled: true))
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        guard let resolution else { return false }
        if case .rejected = resolution { return false }
        return true
    }

    private var promptText: String {
        isTyping ? "Type the aisle number, or what the section is called."
                 : "Say the aisle — “aisle sixteen”, or “bakery”."
    }

    /// Every name and number this store already knows, so the recogniser leans
    /// towards them instead of inventing a near-miss.
    private var aisleHints: [String] {
        store.aisleLayout.flatMap { [$0.name, $0.number] }.filter { !$0.isEmpty }
    }

    private func startTyping() {
        speech.stop()
        isTyping = true
        typed = speech.transcript
        keyboardFocused = true
    }
}

private struct CaptureButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundColor(filled ? DesignSystem.Colors.background : DesignSystem.Colors.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .fill(filled ? DesignSystem.Colors.dillGreen : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                            .stroke(filled ? Color.clear : DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
