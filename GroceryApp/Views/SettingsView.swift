import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @ObservedObject var userCache = UserCache.shared

    @State private var showColorPicker = false
    @State private var currentColor: String = "cyan"
    @State private var currentPattern: String = "solid"

    private var displayName: String {
        guard let userId = amplifyService.currentUser?.userId else { return "User" }
        return userCache.displayName(for: userId)
    }

    private var userInitial: Character? {
        displayName.first
    }

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerView

                    // User info card
                    userInfoCard

                    // App info section
                    appInfoSection

                    // Sign out button
                    signOutButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .navigationBarHidden(true)
        .task {
            await loadCurrentUserProfile()
        }
        .sheet(isPresented: $showColorPicker) {
            ProfileColorPickerSheet(
                selectedColor: $currentColor,
                selectedPattern: $currentPattern,
                onSave: saveProfile
            )
        }
    }

    // MARK: - Load Profile

    private func loadCurrentUserProfile() async {
        guard let userId = amplifyService.currentUser?.userId else { return }
        currentColor = userCache.profileColor(for: userId)
        currentPattern = userCache.profilePattern(for: userId)
    }

    private func saveProfile() {
        Task {
            do {
                try await amplifyService.updateProfileAppearance(color: currentColor, pattern: currentPattern)
            } catch {
                print("Failed to save profile: \(error)")
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Text("Manage your account")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
    }

    // MARK: - User Info Card

    private var userInfoCard: some View {
        Button {
            showColorPicker = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 16) {
                // User color badge
                UserColorBadge(
                    colorKey: currentColor,
                    patternKey: currentPattern,
                    initial: userInitial,
                    size: 60
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)

                    Text("Tap to customize your color")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textTertiary)

                    if amplifyService.currentUser != nil {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(DesignSystem.Colors.success)
                                .frame(width: 6, height: 6)
                            Text("Signed in")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.success)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(glassCard)
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var buildDateString: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return "Unknown"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return fmt.string(from: date)
    }

    // MARK: - App Info Section

    private var appInfoSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                Text("About")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                settingsRow(title: "Version", value: appVersion)
                settingsRow(title: "Build", value: appBuild)
                settingsRow(title: "Built", value: buildDateString)
            }
        }
        .padding(20)
        .background(glassCard)
    }

    private func settingsRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    // MARK: - Sign Out Button

    private var signOutButton: some View {
        Button(action: signOut) {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Sign Out")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.neonPink.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(DesignSystem.Colors.neonPink, lineWidth: 1)
                    )
            )
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

    private func signOut() {
        Task {
            try? await amplifyService.signOut()
        }
    }
}

// MARK: - Custom Text Field

struct CustomTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String = ""
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        HStack(spacing: 12) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .frame(width: 24)
            }

            if isSecure {
                SecureField(placeholder, text: $text)
                    .textInputAutocapitalization(autocapitalization)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autocapitalization)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .foregroundColor(DesignSystem.Colors.textPrimary)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AmplifyService.shared)
}
