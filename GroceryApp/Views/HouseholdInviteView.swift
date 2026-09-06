import SwiftUI

struct HouseholdInviteView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @Environment(\.dismiss) private var dismiss

    @State private var householdDetails: AmplifyService.HouseholdDetails?
    @State private var isLoading = false
    @State private var isRegenerating = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    /// Why the last load failed. Separate from `errorMessage`, which lives
    /// beside the regenerate button and only exists once a code has loaded.
    @State private var loadError: String?
    @State private var showShareSheet = false

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                ScrollView {
                    VStack(spacing: 24) {
                        if isLoading {
                            loadingView
                        } else if let details = householdDetails {
                            if let loadError {
                                Text(loadError)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(DesignSystem.Colors.neonPink)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            inviteCodeSection(details: details)
                            if isCodeLive(details) {
                                shareSection(details: details)
                            }
                        } else {
                            errorView
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("Invite Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
        }
        .task {
            await loadHouseholdDetails()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.dillGreen))
                .scaleEffect(1.5)
            Text("Loading household details...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Error View

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(DesignSystem.Colors.neonPink)

            Text(loadError ?? "Couldn't load your invite code. Check your signal and try again.")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task {
                    await loadHouseholdDetails()
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.dillGreen)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Invite Code Section

    /// Is there anything here worth showing somebody?
    ///
    /// A code rotates and expires the moment it admits somebody, so the usual
    /// state of this screen between invites is a dead string. Nil means the
    /// field was never set, which only happens on rows written before expiry
    /// existed; treat those as live rather than hiding the code from them.
    private func isCodeLive(_ details: AmplifyService.HouseholdDetails) -> Bool {
        details.inviteCodeExpiresAt.map { $0 > Date() } ?? true
    }

    private func inviteCodeSection(details: AmplifyService.HouseholdDetails) -> some View {
        VStack(spacing: 16) {
            // An expired code is not a code. Showing eight dead characters, a
            // QR nothing will accept and a Copy button beside them invites
            // somebody to read it out and wonder why it does not work — the
            // exact confusion this screen exists to prevent. When there is
            // nothing to give away, the screen offers the one useful action.
            if isCodeLive(details) {
                Text("Your Invite Code")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Text(details.inviteCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)
                    .kerning(4)

                // Most invites happen with both people in the room. Reading it
                // out still works and stays above; this is the path that cannot
                // mishear a B for a D.
                InviteQRCode(code: details.inviteCode)

                Text("Point the other phone at this")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                if let expiresAt = details.inviteCodeExpiresAt {
                    Text("Expires \(expiresAt, style: .relative)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            } else {
                Text("Invite someone")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Text("Codes work once and last ten minutes, so there isn't one waiting. Make a fresh one when the other person is with you.")
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Button(action: regenerateCode) {
                HStack {
                    if isRegenerating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Generate New Code")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
            }
            .disabled(isRegenerating)

            // Regenerating is the only thing on this screen that can fail, so
            // the error belongs beside its button. It used to render inside the
            // email section, which meant deleting that section would have made
            // a failed regenerate silent again.
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(glassCard)
    }

    // MARK: - Share Section

    private func shareSection(details: AmplifyService.HouseholdDetails) -> some View {
        VStack(spacing: 16) {
            Text("Share Invite Code")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)

            HStack(spacing: 16) {
                // Copy button
                Button(action: {
                    copyToClipboard(code: details.inviteCode)
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 24))
                        Text("Copy")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.dillGreen.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.dillGreen.opacity(0.3), lineWidth: 1)
                            )
                    )
                }

                // Share button
                Button(action: {
                    showShareSheet = true
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 24))
                        Text("Share")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.neonPurple.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.neonPurple.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
            }

            if let success = successMessage {
                Text(success)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.success)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(glassCard)
        .sheet(isPresented: $showShareSheet) {
            if let details = householdDetails {
                ShareSheet(items: [shareMessage(for: details)])
            }
        }
    }

    // MARK: - Glass Card

    private var glassCard: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func loadHouseholdDetails() async {
        // The catch used to print and fall through to `isLoading = false`, so a
        // failed load looked exactly like a finished one: the spinner stopped
        // and, if a code was already on screen, the stale one just stayed there.
        isLoading = true
        do {
            householdDetails = try await amplifyService.fetchHouseholdDetails()
            loadError = nil
        } catch {
            print("Error loading household details: \(error)")
            loadError = "Couldn't load your invite code. Check your signal and try again."
        }
        isLoading = false
    }

    private func regenerateCode() {
        isRegenerating = true
        errorMessage = nil

        Task {
            do {
                let result = try await amplifyService.regenerateInviteCode()
                householdDetails = AmplifyService.HouseholdDetails(
                    id: householdDetails?.id ?? "",
                    name: householdDetails?.name ?? "",
                    inviteCode: result.inviteCode,
                    inviteCodeExpiresAt: result.expiresAt,
                    memberCount: householdDetails?.memberCount ?? 0,
                    members: householdDetails?.members ?? [],
                    ownerId: householdDetails?.ownerId
                )
                successMessage = "New code generated!"

                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    successMessage = nil
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRegenerating = false
        }
    }

    private func copyToClipboard(code: String) {
        UIPasteboard.general.string = code
        successMessage = "Code copied to clipboard!"

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            successMessage = nil
        }
    }

    private func shareMessage(for details: AmplifyService.HouseholdDetails) -> String {
        """
        \(AppIdentity.name) — join my household "\(details.name)".

        Use this invite code: \(details.inviteCode)

        It works once, and expires in 10 minutes.
        """
    }

}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    HouseholdInviteView()
        .environmentObject(AmplifyService.shared)
}
