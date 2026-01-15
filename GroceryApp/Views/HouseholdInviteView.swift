import SwiftUI

struct HouseholdInviteView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @Environment(\.dismiss) private var dismiss

    @State private var householdDetails: AmplifyService.HouseholdDetails?
    @State private var isLoading = false
    @State private var isRegenerating = false
    @State private var isSendingEmail = false
    @State private var recipientEmail = ""
    @State private var senderName = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
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
                            inviteCodeSection(details: details)
                            shareSection(details: details)
                            emailSection
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
                    .foregroundColor(DesignSystem.Colors.neonCyan)
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
                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.neonCyan))
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

            Text("Failed to load household details")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Button("Try Again") {
                Task {
                    await loadHouseholdDetails()
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.neonCyan)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Invite Code Section

    private func inviteCodeSection(details: AmplifyService.HouseholdDetails) -> some View {
        VStack(spacing: 16) {
            Text("Your Invite Code")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)

            Text(details.inviteCode)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .kerning(6)

            if let expiresAt = details.inviteCodeExpiresAt {
                if expiresAt > Date() {
                    Text("Expires \(expiresAt, style: .relative)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                } else {
                    Text("Code expired - regenerate below")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.neonPink)
                }
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
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.neonCyan.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.neonCyan.opacity(0.3), lineWidth: 1)
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

    // MARK: - Email Section

    private var emailSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "envelope.fill")
                    .foregroundColor(DesignSystem.Colors.neonPink)
                Text("Send Email Invitation")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            CustomTextField(
                placeholder: "Your Name",
                text: $senderName,
                icon: "person.fill"
            )

            CustomTextField(
                placeholder: "Recipient Email",
                text: $recipientEmail,
                icon: "envelope",
                keyboardType: .emailAddress,
                autocapitalization: .never
            )

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .multilineTextAlignment(.center)
            }

            Button(action: sendEmail) {
                HStack {
                    if isSendingEmail {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text("Send Invitation")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.accentGradient2)
                )
            }
            .disabled(isSendingEmail || recipientEmail.isEmpty || senderName.isEmpty)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(glassCard)
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
        isLoading = true
        do {
            householdDetails = try await amplifyService.fetchHouseholdDetails()
        } catch {
            print("Error loading household details: \(error)")
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
                    members: householdDetails?.members ?? []
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
        Join my household "\(details.name)" on NotOurGroceries!

        Use this invite code: \(details.inviteCode)

        The code expires in 24 hours.
        """
    }

    private func sendEmail() {
        isSendingEmail = true
        errorMessage = nil

        Task {
            do {
                let result = try await amplifyService.sendInviteEmail(to: recipientEmail, senderName: senderName)
                if result.success {
                    successMessage = result.message ?? "Invitation sent!"
                    recipientEmail = ""
                } else {
                    errorMessage = result.message ?? "Failed to send email"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSendingEmail = false

            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }
        }
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
