import SwiftUI

struct HouseholdView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @Environment(\.scenePhase) private var scenePhase
    @State private var householdName = ""
    @State private var inviteCode = ""
    @State private var isCreating = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showInviteSheet = false
    @State private var showLeaveAlert = false
    @State private var showJoinSheet = false
    /// Who the owner is about to remove. Nil when no removal is pending.
    @State private var memberToRemove: AmplifyService.HouseholdMember?
    @State private var householdDetails: AmplifyService.HouseholdDetails?

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

                    if amplifyService.currentHouseholdId != nil {
                        hasHouseholdView
                    } else {
                        noHouseholdView
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .refreshable {
                await loadHouseholdDetails()
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showInviteSheet) {
            HouseholdInviteView()
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinHouseholdSheet(isPresented: $showJoinSheet)
        }
        .alert("Leave Household?", isPresented: $showLeaveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                leaveHousehold()
            }
        } message: {
            Text(leaveWarning)
        }
        .alert(
            "Remove \(memberToRemove?.displayName ?? "member")?",
            isPresented: Binding(
                get: { memberToRemove != nil },
                set: { if !$0 { memberToRemove = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { memberToRemove = nil }
            Button("Remove", role: .destructive) {
                if let member = memberToRemove { removeMember(member) }
            }
        } message: {
            Text("They lose access to the list immediately. Anything they added stays — it belongs to the household. You can invite them back with a new code.")
        }
        .task {
            await loadHouseholdDetails()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await loadHouseholdDetails() }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Household")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)

                Text(statusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            // Logged-in user label
            if let userId = amplifyService.currentUser?.userId {
                Text(UserCache.shared.displayName(for: userId))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary.opacity(0.7))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
    }

    private var statusText: String {
        if amplifyService.currentHouseholdId != nil {
            return householdDetails?.name ?? "Your household"
        } else {
            return "Create or join a household to share lists"
        }
    }

    // MARK: - Has Household View

    private var hasHouseholdView: some View {
        VStack(spacing: 24) {
            // Household info card
            VStack(spacing: 16) {
                Image(systemName: "house.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)

                if let details = householdDetails {
                    Text(details.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)

                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 14))
                        Text("\(details.memberCount) member\(details.memberCount == 1 ? "" : "s")")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                } else {
                    Text("Your Household")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(glassCard)

            // Members Section
            if let details = householdDetails, !details.members.isEmpty {
                membersSection(details.members)
            }

            // Invite Members button
            Button(action: { showInviteSheet = true }) {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text("Invite Members")
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

            // Leave household option
            Button(action: { showLeaveAlert = true }) {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Leave Household")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.neonPink)
            }
        }
    }

    // MARK: - Members Section

    private func membersSection(_ members: [AmplifyService.HouseholdMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                Text("MEMBERS")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                    .tracking(1.2)
            }
            .padding(.horizontal, 4)

            // Members list
            VStack(spacing: 0) {
                ForEach(members) { member in
                    memberRow(member)

                    if member.id != members.last?.id {
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                }
            }
            .background(glassCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func memberRow(_ member: AmplifyService.HouseholdMember) -> some View {
        let isCurrentUser = member.id == amplifyService.currentUser?.userId

        return HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        isCurrentUser
                            ? DesignSystem.Colors.accentGradient
                            : LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.white.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: 40, height: 40)

                Text(String(member.displayName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)

                    if isCurrentUser {
                        Text("(you)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.dillGreen)
                    }
                }

                Text(member.email)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            // Joined date
            if let joinedAt = member.joinedAt {
                Text(joinedAt, style: .date)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary.opacity(0.7))
            }

            // Only the creator sees this, and never on their own row. Behind a
            // long press rather than a visible button: it is rare, it is not
            // undoable, and a tappable X beside somebody's name invites a
            // mis-tap in a household of two.
            if canRemove(member) {
                Menu {
                    Button("Remove \(member.displayName)", role: .destructive) {
                        memberToRemove = member
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - No Household View

    private var noHouseholdView: some View {
        VStack(spacing: 20) {
            // Toggle between create / join
            Picker("Mode", selection: $isCreating) {
                Text("Create New").tag(true)
                Text("Join Existing").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            // Form
            VStack(spacing: 16) {
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

                // Success message
                if let success = successMessage {
                    Text(success)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.dillGreen)
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
            }
            .padding(20)
            .background(glassCard)
        }
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

            Text("Start a household and invite others with a code")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            CustomTextField(
                placeholder: "Household Name",
                text: $householdName,
                icon: "house"
            )
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

        isLoading = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                let result = try await amplifyService.createHouseholdRemotely(name: householdName)
                successMessage = result.inviteCode.map { "Household created — invite code \($0)" }
                    ?? "Household created"
                householdName = ""
                await loadHouseholdDetails()
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
        successMessage = nil

        Task {
            do {
                // The Lambda, not the client path. Household rows are scoped to their
                // Cognito group now, so somebody who is not yet a member cannot read
                // the household they are trying to join — the direct query returns
                // nothing and the join silently fails. The Lambda runs with IAM, and
                // it is also the only path that checks the code has not expired.
                _ = try await amplifyService.joinHouseholdWithCode(inviteCode.uppercased())
                successMessage = "Successfully joined household!"
                inviteCode = ""
                await loadHouseholdDetails()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// The last member out takes the household with them, and that is worth
    /// saying before they tap rather than after.
    private var leaveWarning: String {
        if (householdDetails?.memberCount ?? 0) <= 1 {
            return "You are the only member, so the household will be deleted along with its list, suggestions, history and store layouts. This cannot be undone."
        }
        return "You will lose access to the shared shopping list. Anything you added stays with the household. You can rejoin later with an invite code."
    }

    /// Only the creator, and never on their own row.
    private func canRemove(_ member: AmplifyService.HouseholdMember) -> Bool {
        guard let ownerId = householdDetails?.ownerId,
              let me = amplifyService.currentUser?.userId else { return false }
        return ownerId == me && member.id != me
    }

    private func removeMember(_ member: AmplifyService.HouseholdMember) {
        memberToRemove = nil
        Task {
            do {
                _ = try await amplifyService.removeMember(member.id)
                successMessage = "\(member.displayName) was removed"
                await loadHouseholdDetails()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadHouseholdDetails() async {
        do {
            householdDetails = try await amplifyService.fetchHouseholdDetails()
        } catch {
            print("Error loading household details: \(error)")
        }
    }

    private func leaveHousehold() {
        Task {
            do {
                // Goes through the Lambda now: the old path wrote an empty
                // string into a GSI key and left the household standing with
                // nobody in it.
                _ = try await amplifyService.leaveHouseholdRemotely()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            householdDetails = nil
        }
    }
}

// MARK: - Join Household Sheet

struct JoinHouseholdSheet: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @Binding var isPresented: Bool
    @State private var inviteCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showWarning = false

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                VStack(spacing: 24) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 50))
                        .foregroundStyle(DesignSystem.Colors.accentGradient)

                    Text("Switch Household")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)

                    Text("Enter the invite code for the household you want to join. You'll leave your current household.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    CustomTextField(
                        placeholder: "Invite Code",
                        text: $inviteCode,
                        icon: "ticket",
                        autocapitalization: .characters
                    )
                    .padding(.horizontal, 20)

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.neonPink)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: { showWarning = true }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "person.badge.plus")
                                Text("Join Household")
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
                    .disabled(isLoading || inviteCode.isEmpty)
                    .padding(.horizontal, 20)

                    Spacer()
                }
                .padding(.top, 40)
            }
            .navigationTitle("Switch Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
            .alert("Leave Current Household?", isPresented: $showWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Switch", role: .destructive) {
                    joinNewHousehold()
                }
            } message: {
                Text("You will leave your current household and join the new one. You can rejoin your old household later with an invite code.")
            }
        }
    }

    private func joinNewHousehold() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await amplifyService.joinHouseholdWithCode(inviteCode.uppercased())
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    HouseholdView()
        .environmentObject(AmplifyService.shared)
}
