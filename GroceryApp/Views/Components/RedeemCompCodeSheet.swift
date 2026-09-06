import SwiftUI

/// Type a code, get comped.
///
/// The whole of the first-hundred onboarding, and it is deliberately one field
/// and one button: "install, enter the code, get comped, done". Every outcome
/// leaves the person using the app — a bad code says so and lets them carry on
/// free, because a code screen that blocks the door is worse than no code screen.
struct RedeemCompCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var allowances = AllowanceService.shared

    @State private var code = ""
    @State private var isRedeeming = false
    @State private var outcome: Outcome?
    @FocusState private var fieldFocused: Bool

    private struct Outcome: Equatable {
        let succeeded: Bool
        let message: String
    }

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

                VStack(spacing: 24) {
                    header
                    field
                    if let outcome { outcomeCard(outcome) }
                    redeemButton
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Redeem a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(outcome?.succeeded == true ? "Done" : "Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { fieldFocused = true }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "ticket.fill")
                .font(.system(size: 44))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Text("Got a code?")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Text("It lifts every limit for your whole household, for good.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var field: some View {
        // Codes are read off a screen or heard down a phone, so spaces, dashes
        // and casing are all forgiven server-side. Autocorrect is off because it
        // rewrites short letter runs into words.
        TextField("", text: $code, prompt: Text("Your code").foregroundColor(DesignSystem.Colors.textTertiary))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.system(size: 20, weight: .semibold, design: .monospaced))
            .foregroundColor(DesignSystem.Colors.textPrimary)
            .multilineTextAlignment(.center)
            .focused($fieldFocused)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(DesignSystem.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(DesignSystem.Colors.dillGreen.opacity(0.35), lineWidth: 1)
                    )
            )
            .onChange(of: code) { _, _ in outcome = nil }
    }

    private func outcomeCard(_ outcome: Outcome) -> some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
            Text(outcome.message)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(outcome.succeeded ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.neonAmber)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill((outcome.succeeded ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.neonAmber).opacity(0.12))
        )
    }

    private var redeemButton: some View {
        Button {
            Task { await redeem() }
        } label: {
            HStack {
                if isRedeeming {
                    ProgressView().tint(.white)
                } else {
                    Text("Redeem")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(DesignSystem.Colors.accentGradient)
                    .opacity(canRedeem ? 1 : 0.4)
            )
        }
        .disabled(!canRedeem)
    }

    private var canRedeem: Bool {
        !isRedeeming
            && outcome?.succeeded != true
            && code.trimmingCharacters(in: .whitespaces).count >= 4
    }

    private func redeem() async {
        isRedeeming = true
        defer { isRedeeming = false }
        fieldFocused = false

        let result = await allowances.redeemCompCode(code)
        outcome = Outcome(succeeded: result.succeeded, message: result.message)
        if result.succeeded {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
