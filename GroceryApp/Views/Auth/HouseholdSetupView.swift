import SwiftUI

struct HouseholdSetupView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @State private var householdName = ""
    @State private var inviteCode = ""
    @State private var isCreating = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isCheckingName = false

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    headerSection
                        .padding(.top, 80)

                    // Toggle and form
                    formSection

                    Spacer(minLength: 50)
                }
                .padding(.horizontal, 24)
            }
        }
        .onAppear {
            setDefaultHouseholdName()
        }
    }

    private func setDefaultHouseholdName() {
        guard householdName.isEmpty else { return }
        if let user = amplifyService.currentUser {
            // Extract name from email (before @) and capitalize
            let email = user.username
            if let atIndex = email.firstIndex(of: "@") {
                let namePart = String(email[..<atIndex])
                let capitalized = namePart.capitalized
                householdName = "\(capitalized)'s Household"
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "house.fill")
                .font(.system(size: 70))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .neonGlow(color: DesignSystem.Colors.neonPurple)

            Text("Set Up Your Household")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Text("Create a new household or join an existing one")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Form Section

    private var formSection: some View {
        VStack(spacing: 24) {
            // Toggle between create / join
            Picker("Mode", selection: $isCreating) {
                Text("Create New").tag(true)
                Text("Join Existing").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)
            .onChange(of: isCreating) { _ in
                errorMessage = nil
            }

            if isCreating {
                createHouseholdForm
            } else {
                joinHouseholdForm
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .multilineTextAlignment(.center)
            }

            // Submit button
            Button(action: isCreating ? createHousehold : joinHousehold) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: isCreating ? "plus.circle.fill" : "person.badge.plus")
                        Text(isCreating ? "Create Household" : "Join Household")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.accentGradient)
                )
            }
            .disabled(isLoading)

            // Sign out option
            Button(action: signOut) {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign Out")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .background(glassCard)
    }

    // MARK: - Create Household Form

    private var createHouseholdForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "house.fill")
                .font(.system(size: 40))
                .foregroundColor(DesignSystem.Colors.neonCyan)

            Text("Create a new household")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text("Choose a unique name for your household")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            HStack {
                CustomTextField(
                    placeholder: "Household Name",
                    text: $householdName,
                    icon: "house"
                )

                if isCheckingName {
                    ProgressView()
                        .tint(DesignSystem.Colors.neonCyan)
                }
            }
            .onChange(of: householdName) { newValue in
                errorMessage = nil
            }

            Text("e.g., The Smith Family, Our Place, Home Base")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    // MARK: - Join Household Form

    private var joinHouseholdForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(DesignSystem.Colors.neonPurple)

            Text("Join an existing household")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text("Enter the invite code shared by a household member")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            CustomTextField(
                placeholder: "Invite Code (e.g., ABC123)",
                text: $inviteCode,
                icon: "ticket",
                autocapitalization: .characters
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

    private func createHousehold() {
        guard !householdName.isEmpty else {
            errorMessage = "Please enter a household name"
            return
        }

        guard householdName.count >= 3 else {
            errorMessage = "Household name must be at least 3 characters"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Check if name is available
                let isAvailable = try await amplifyService.checkHouseholdNameAvailable(name: householdName)
                if !isAvailable {
                    errorMessage = "This household name is already taken. Please choose another."
                    isLoading = false
                    return
                }

                // Create the household
                _ = try await amplifyService.createHousehold(name: householdName)
                // RootView will automatically navigate to ContentView when householdId is set
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func joinHousehold() {
        guard !inviteCode.isEmpty else {
            errorMessage = "Please enter an invite code"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await amplifyService.joinHousehold(inviteCode: inviteCode.uppercased())
                // RootView will automatically navigate to ContentView when householdId is set
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func signOut() {
        Task {
            try? await amplifyService.signOut()
        }
    }
}

#Preview {
    HouseholdSetupView()
        .environmentObject(AmplifyService.shared)
}
