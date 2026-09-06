import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject var userCache = UserCache.shared

    // Your colour tints the [name] under every item you add, which is the only
    // thing telling your rows from anyone else's on a shared list. It is assigned
    // at random when you join, and changeable here because it is a pleasant thing
    // to change and costs nothing.
    //
    // Colours already worn by other members are shown but not selectable — two
    // people sharing one would make the attribution meaningless, which is the
    // whole reason the colour exists.
    @State private var currentColor: String = "cyan"
    @State private var showColorPicker = false

    @State private var showClearWarning = false
    @State private var showTypeToConfirm = false
    @State private var confirmationText = ""
    @State private var isClearing = false
    @State private var clearProgress: (done: Int, total: Int) = (0, 0)

    @State private var showAllowances = false
    @ObservedObject private var allowances = AllowanceService.shared

    /// Sign out wipes four local stores on the way out, three of which are the
    /// only copy. The card says which, so the tap is informed.
    @State private var showSignOutWarning = false

    @State private var showDeleteAccountWarning = false
    @State private var showDeleteAccountConfirm = false
    @State private var deleteConfirmationText = ""
    @State private var isDeletingAccount = false
    @State private var deleteError: String?

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

                    // Plan and allowances
                    planSection

                    // App info section
                    appInfoSection

                    // Destructive, and kept away from everything else
                    dangerZone

                    // Sign out button
                    signOutButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showAllowances) {
            AllowancesView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showColorPicker) {
            ProfileColorPickerSheet(
                selectedColor: $currentColor,
                takenColors: takenColors,
                initial: userInitial,
                onSave: saveColor
            )
        }
        .task {
            await loadCurrentUserProfile()
        }
        .signOutWarning($showSignOutWarning, onConfirm: signOut)
    }

    // MARK: - Load Profile

    private func loadCurrentUserProfile() async {
        guard let userId = amplifyService.currentUser?.userId else { return }
        currentColor = userCache.profileColor(for: userId)
    }

    /// Colours worn by other household members, mapped to their initial so the
    /// picker can say who has each one rather than just refusing it.
    private var takenColors: [String: Character] {
        let me = amplifyService.currentUser?.userId
        var taken: [String: Character] = [:]
        for user in userCache.users.values where user.id != me {
            guard let colour = user.profileColor, let initial = user.displayName.first else { continue }
            taken[colour] = initial
        }
        return taken
    }

    private func saveColor() {
        Task {
            do {
                try await amplifyService.updateProfileAppearance(color: currentColor)
            } catch {
                // Nothing is lost — the badge shows the chosen colour until the
                // next refresh, and the next launch reads whatever the server
                // kept. Worth a line in the log rather than a scary alert over a
                // colour.
                print("Could not save profile colour: \(error)")
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
        HStack(spacing: 16) {
            // Tap to recolour. The badge is the only thing on this screen that
            // does anything, so it is the affordance.
            Button {
                showColorPicker = true
            } label: {
                UserColorBadge(
                    colorKey: currentColor,
                    initial: userInitial,
                    size: 60
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change your profile colour")

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

            }

        Spacer()
    }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(glassCard)
    }

    // MARK: - App Info

    private var appVersion: String { AppVersion.marketing }

    private var appBuild: String { AppVersion.build }

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

    // MARK: - Plan

    /// One row: which plan the household is on, and the way to the allowances
    /// page. Comped households are told they are comped.
    private var planSection: some View {
        Button {
            showAllowances = true
        } label: {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                Text("Plan")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Spacer()
                Text(allowances.summary?.plan.label ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
            .padding(20)
            .background(glassCard)
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Info Section

    private var appInfoSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                Text("About")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                settingsRow(title: "Version", value: appVersion)
                settingsRow(title: "Build", value: appBuild)
                settingsRow(title: "Built", value: buildDateString)

                // Reachable after signup too, not only on the screen where it
                // was accepted.
                Link(destination: AppIdentity.privacyPolicyURL) {
                    HStack {
                        Text("Privacy Policy")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.dillGreen)
                    }
                }
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

    // MARK: - Danger Zone

    /// Empty the suggestions, all of them, for the whole household.
    ///
    /// Suggestions accumulate by design and there is no other way to remove more
    /// than one at a time — a few hundred bad ones from an early experiment can
    /// otherwise only be swiped away individually.
    ///
    /// Guarded in three steps because it cannot be undone and it is not only the
    /// tapper's data: a warning naming the count, then typing the word, then the
    /// work itself. Each step says the same two facts — everyone loses them, and
    /// there is no undo — because a person who skims the first will read the
    /// second.
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DANGER ZONE")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundColor(DesignSystem.Colors.error.opacity(0.8))

            Button {
                showClearWarning = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.error)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear all suggestions")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textPrimary)
                        Text(suggestionSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }

                    Spacer(minLength: 0)

                    if isClearing {
                        Text("\(clearProgress.done)/\(clearProgress.total)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.error.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(DesignSystem.Colors.error.opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isClearing || viewModel.suggestions.isEmpty)
            .opacity(viewModel.suggestions.isEmpty ? 0.45 : 1)

            Button {
                deleteConfirmationText = ""
                showDeleteAccountWarning = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.error)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete my account")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textPrimary)
                        Text(deleteAccountSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }

                    Spacer(minLength: 0)

                    if isDeletingAccount {
                        ProgressView().tint(DesignSystem.Colors.error)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.error.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(DesignSystem.Colors.error.opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isDeletingAccount)

            if let deleteError {
                Text(deleteError)
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Delete all \(viewModel.suggestions.count) suggestions?",
            isPresented: $showClearWarning,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                confirmationText = ""
                showTypeToConfirm = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This empties the suggestion list for everyone in the household, not just on this phone. It cannot be undone, and your shopping history is how the app knows what you buy.")
        }
        .sheet(isPresented: $showTypeToConfirm) {
            typeToConfirmSheet
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteAccountWarning,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                deleteConfirmationText = ""
                showDeleteAccountConfirm = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteAccountWarning)
        }
        .sheet(isPresented: $showDeleteAccountConfirm) {
            deleteAccountSheet
        }
    }

    /// What actually happens, which depends on whether anyone else is left.
    private var isOnlyMember: Bool {
        userCache.users.count <= 1
    }

    private var deleteAccountSubtitle: String {
        isOnlyMember
            ? "Removes your sign-in and this household"
            : "Removes your sign-in; the household carries on"
    }

    private var deleteAccountWarning: String {
        isOnlyMember
            ? "You are the only member, so the household goes with you — the list, the stores, the aisle layouts and the history. Your sign-in is deleted and cannot be recovered."
            : "Your sign-in is deleted and cannot be recovered. Items you added stay on the household list, and the other members carry on as normal."
    }

    private var deleteAccountSheet: some View {
        VStack(spacing: 24) {
            Text("Delete account")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text(deleteAccountWarning)
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Text("Type DELETE to confirm")
                .font(.system(size: 12))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            TextField("", text: $deleteConfirmationText)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .multilineTextAlignment(.center)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                )

            Button {
                showDeleteAccountConfirm = false
                Task { await deleteAccount() }
            } label: {
                Text("Delete my account")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.error)
                    )
            }
            .buttonStyle(.plain)
            .disabled(deleteConfirmationText.trimmingCharacters(in: .whitespaces).uppercased() != "DELETE")
            .opacity(deleteConfirmationText.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" ? 1 : 0.4)

            Button("Cancel") { showDeleteAccountConfirm = false }
                .foregroundColor(DesignSystem.Colors.textSecondary)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(DesignSystem.Colors.background.ignoresSafeArea())
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        deleteError = nil
        do {
            try await amplifyService.deleteAccount()
            // Nothing to dismiss — the session is gone, so the app returns to
            // the sign-in screen on its own.
        } catch {
            deleteError = "Could not delete your account: \(error.localizedDescription)"
            print("Delete account failed: \(error)")
        }
        isDeletingAccount = false
    }

    private var suggestionSubtitle: String {
        let count = viewModel.suggestions.count
        if count == 0 { return "Nothing to clear" }
        return count == 1
            ? "1 suggestion · everyone in the household"
            : "\(count) suggestions · everyone in the household"
    }

    /// The last gate. Typing the word is the point — it is the one action a thumb
    /// cannot perform by accident on the way to something else.
    private var typeToConfirmSheet: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("Last chance")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Text("You are about to delete **\(viewModel.suggestions.count) suggestions** from your household. Everyone loses them. There is no undo, and nothing on your current shopping list is touched.")
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Text("Type DELETE to confirm")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                TextField("", text: $confirmationText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.cardBackground)
                    )

                Button {
                    showTypeToConfirm = false
                    Task { await clearSuggestions() }
                } label: {
                    Text("Delete them all")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DesignSystem.Colors.error)
                        )
                }
                .buttonStyle(.plain)
                .disabled(confirmationText != "DELETE")
                .opacity(confirmationText == "DELETE" ? 1 : 0.4)

                Button("Cancel") { showTypeToConfirm = false }
                    .font(.system(size: 15))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity)

                Spacer()
            }
            .padding(24)
        }
        .presentationDetents([.medium])
    }

    private func clearSuggestions() async {
        isClearing = true
        clearProgress = (0, viewModel.suggestions.count)
        await viewModel.deleteAllSuggestions { done, total in
            clearProgress = (done, total)
        }
        isClearing = false
        confirmationText = ""
    }

    // MARK: - Sign Out Button

    private var signOutButton: some View {
        Button { showSignOutWarning = true } label: {
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
            // `try?` meant a failed sign-out left the user signed in with no
            // word of it, right after a warning that said their local data was
            // about to be cleared.
            do {
                try await amplifyService.signOut()
            } catch {
                print("Sign out failed: \(error)")
                viewModel.showToast(
                    message: "Couldn't complete sign out. Check your signal and try again.",
                    type: .error
                )
            }
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
    /// Tells iOS what this field holds. Without it, AutoFill, iCloud Keychain
    /// and 1Password have no idea which box is the username and which is the
    /// password, so they never offer to fill anything.
    var contentType: UITextContentType? = nil

    /// The visible box is bigger than the text field inside it. Without this the
    /// icon and the 16pt of padding are dead space, so the first tap does nothing
    /// and it feels like the field needs tapping twice.
    @FocusState private var isFocused: Bool

    /// Typing a password blind is miserable, and on a phone keyboard it's the
    /// main reason people get locked out of their own account.
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 12) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .frame(width: 24)
            }

            if isSecure {
                Group {
                    if isRevealed {
                        TextField(placeholder, text: $text)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .textContentType(contentType)
                .focused($isFocused)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autocapitalization)
                    .textContentType(contentType)
                    .autocorrectionDisabled(contentType != nil)
                    .focused($isFocused)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
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
