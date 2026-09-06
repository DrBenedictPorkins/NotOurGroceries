import SwiftUI

struct HouseholdSetupView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @State private var householdName = ""
    @State private var inviteCode = ""
    @State private var showScanner = false
    @State private var isCreating = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isCheckingName = false
    /// Someone can land here holding a Quick Trip list and a track record — after
    /// being removed from a household, say — so this exit warns like the other.
    @State private var showSignOutWarning = false

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
        .sheet(isPresented: $showScanner) {
            scannerSheet
        }
        .signOutWarning($showSignOutWarning, onConfirm: signOut)
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
            Button { showSignOutWarning = true } label: {
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
                .foregroundColor(DesignSystem.Colors.dillGreen)

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
                        .tint(DesignSystem.Colors.dillGreen)
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
                placeholder: "Invite Code",
                text: $inviteCode,
                icon: "ticket",
                autocapitalization: .characters
            )

            // The code is eight characters read off someone else's screen.
            // Scanning it is both faster and the only way that cannot mistake a
            // B for a D. Typing stays, for a code sent by text.
            Button {
                showScanner = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Scan their code instead")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(DesignSystem.Colors.neonPurple)
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

    private var scannerSheet: some View {
        NavigationView {
            QRScanner { scanned in
                // Invite codes are upper-case; the scanner no longer shouts what
                // it reads, so the casing is fixed here where it applies.
                inviteCode = scanned.uppercased()
                showScanner = false
                joinHousehold()
            }
            .ignoresSafeArea()
            .navigationTitle("Scan invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showScanner = false }
                }
            }
        }
    }

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

                // Goes through the Lambda: it owns the invite code, the owner,
                // and the Cognito group without which the creator cannot read
                // the household they just made.
                let result = try await amplifyService.createHouseholdRemotely(name: householdName)
                // RootView will automatically navigate to ContentView when householdId is set

                // Seeding runs once and is never retried, so a household created
                // while the network was flaky comes up with no shops at all. This
                // is the path most households are created on, so it is the one
                // that most needs to say so.
                if !result.startingStoresFailed.isEmpty {
                    errorMessage = "Your household is ready, but its starting shops couldn't be created. Add one yourself from Select Store."
                }
            } catch {
                let failure = ServiceFailure.from(error)
                errorMessage = failure.sentence
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
                // The Lambda, not the client path. Household rows are scoped to their
                // Cognito group now, so somebody who is not yet a member cannot read
                // the household they are trying to join — the direct query returns
                // nothing and the join silently fails. The Lambda runs with IAM, and
                // it is also the only path that checks the code has not expired.
                _ = try await amplifyService.joinHouseholdWithCode(inviteCode.uppercased())
                // RootView will automatically navigate to ContentView when householdId is set
            } catch {
                let failure = ServiceFailure.from(error)
                errorMessage = failure.sentence
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
