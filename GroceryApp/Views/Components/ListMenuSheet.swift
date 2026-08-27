import SwiftUI

/// What opens when you tap the list title. A real panel rather than a dropdown —
/// it holds everything that shouldn't permanently occupy the header: who you are,
/// which household, the modes, and the build you're running.
struct ListMenuSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @EnvironmentObject var amplifyService: AmplifyService
    @ObservedObject private var userCache = UserCache.shared
    @ObservedObject private var paperMode = PaperMode.shared

    var onAtStore: () -> Void
    var onQuickTrip: () -> Void
    var onPaperList: () -> Void
    var onSignOut: () -> Void

    private var displayName: String {
        guard let userId = amplifyService.currentUser?.userId else { return "You" }
        return userCache.displayName(for: userId)
    }

    private var profileColor: String {
        guard let userId = amplifyService.currentUser?.userId else { return "cyan" }
        return userCache.profileColor(for: userId)
    }

    private var profilePattern: String {
        guard let userId = amplifyService.currentUser?.userId else { return "solid" }
        return userCache.profilePattern(for: userId)
    }

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

            ScrollView {
                VStack(spacing: 18) {
                    identityCard

                    section("Start shopping") {
                        row(
                            icon: "cart.fill",
                            tint: DesignSystem.Colors.dillGreen,
                            title: "At Store",
                            detail: "Full trip, sorted by aisle. Everyone sees you're shopping.",
                            disabled: !canStartShopping
                        ) {
                            isPresented = false
                            onAtStore()
                        }

                        row(
                            icon: "figure.walk.motion",
                            tint: DesignSystem.Colors.neonPurple,
                            title: "Quick Trip",
                            detail: "A few things somewhere else. Your main list stays untouched.",
                            disabled: !canStartShopping
                        ) {
                            isPresented = false
                            onQuickTrip()
                        }

                        row(
                            icon: "doc.plaintext.fill",
                            tint: DesignSystem.Colors.neonAmber,
                            title: paperMode.isActive ? "On paper list" : "Paper List",
                            detail: paperMode.isActive
                                ? "Not talking to the server. Tap the banner to reconnect."
                                : "No signal? Stop calling the server and just shop.",
                            disabled: paperMode.isActive
                        ) {
                            isPresented = false
                            onPaperList()
                        }
                    }

                    section("This build") {
                        infoRow("Version", appVersion)
                        infoRow("Build", appBuild)
                        infoRow("Backend", "Production")
                    }

                    signOutButton

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        HStack(spacing: 14) {
            UserColorBadge(
                colorKey: profileColor,
                patternKey: profilePattern,
                initial: displayName.first,
                size: 52
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)

                Text(householdLine)
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(card)
    }

    /// Modes are only offered when nobody is mid-session.
    private var canStartShopping: Bool {
        viewModel.shoppingStatus == .idle && !paperMode.isActive
    }

    private var householdLine: String {
        let members = userCache.users.count
        guard members > 0 else { return "Signed in" }
        return "\(members) in the household"
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .padding(.leading, 4)

            VStack(spacing: 10) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(tint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(card)
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(card)
    }

    private var signOutButton: some View {
        Button(action: {
            isPresented = false
            onSignOut()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Sign Out")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(DesignSystem.Colors.neonPink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.neonPink.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(DesignSystem.Colors.neonPink.opacity(0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
