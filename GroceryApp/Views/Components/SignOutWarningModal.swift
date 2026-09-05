import SwiftUI

/// What signing out actually costs, before it happens.
///
/// Sign out is not just "log in again". `AmplifyService.clearLocalUserData()`
/// wipes four local stores on the way out, deliberately and unconditionally, so
/// the next person to sign in on this phone does not inherit the last one's
/// data. Three of those four are the only copy that exists:
///
/// - the outbox, whose queued writes never reach the household,
/// - the Quick Trip list, which is this phone only and never synced,
/// - the track record, which is counted on this phone and never uploaded, and
///   which is also what "Restore last trip" restores from.
///
/// The shopping list itself is on the server and comes back on the next sign in,
/// so it is named as safe rather than left to worry about.
///
/// The card lists only what this phone is actually about to lose. A warning that
/// lists things you do not have teaches people to tap through warnings.
struct SignOutWarningModal: View {
    let onSignOut: () -> Void
    let onCancel: () -> Void

    private let accent = DesignSystem.Colors.neonPink

    /// Read once, when the card is built, so the numbers cannot shift underneath
    /// the person reading them.
    private struct Loss: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        /// Unsent work is a different order of problem from a scratch list.
        let severe: Bool
    }

    private var losses: [Loss] {
        var out: [Loss] = []

        let pending = Outbox.shared.count
        if pending > 0 {
            out.append(Loss(
                icon: "exclamationmark.icloud",
                text: pending == 1
                    ? "1 change hasn't reached the household yet. It will be dropped."
                    : "\(pending) changes haven't reached the household yet. They will be dropped.",
                severe: true
            ))
        }

        let quick = QuickListStore.shared.lines.count
        if quick > 0 {
            out.append(Loss(
                icon: "list.bullet.rectangle.portrait",
                text: quick == 1
                    ? "Your Quick Trip list, 1 item. It is on this phone only."
                    : "Your Quick Trip list, \(quick) items. It is on this phone only.",
                severe: false
            ))
        }

        let stats = TripStats.shared
        if stats.hasAnything {
            var parts: [String] = []
            if stats.tripCount > 0 { parts.append(stats.tripCount == 1 ? "1 trip" : "\(stats.tripCount) trips") }
            if stats.quickTripCount > 0 { parts.append(stats.quickTripCount == 1 ? "1 quick trip" : "\(stats.quickTripCount) quick trips") }
            out.append(Loss(
                icon: "chart.bar",
                text: "Your track record, \(parts.joined(separator: " and "))"
                    + (stats.restorableTrip != nil ? ", and the trip you could still restore." : "."),
                severe: false
            ))
        }

        return out
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { }

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.15))
                        .frame(width: 76, height: 76)
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(accent)
                }

                Text("Sign out?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                let losses = losses

                if losses.isEmpty {
                    Text("You'll need your password to sign back in. Your list stays safe on the server.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                } else {
                    Text("This phone loses:")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textSecondary)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(losses) { loss in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: loss.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(loss.severe ? DesignSystem.Colors.neonAmber : DesignSystem.Colors.textTertiary)
                                    .frame(width: 20)
                                Text(loss.text)
                                    .font(.system(size: 14, weight: loss.severe ? .semibold : .regular))
                                    .foregroundColor(loss.severe ? DesignSystem.Colors.neonAmber : DesignSystem.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                            )
                    )

                    // Said out loud so the list above is read as complete. The
                    // shopping list is the thing people are actually afraid of
                    // losing, and it is the one thing that is safe.
                    Text("Your shopping list is on the server and comes back when you sign in.")
                        .font(.system(size: 13))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSignOut()
                } label: {
                    Text("Sign Out")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(accent.opacity(0.35))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(accent, lineWidth: 1)
                                )
                        )
                }
                .padding(.top, 2)

                Button("Cancel", action: onCancel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(26)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(DesignSystem.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(LinearGradient(
                                colors: [accent.opacity(0.5), accent.opacity(0.2)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ), lineWidth: 1.5)
                    )
                    .shadow(color: accent.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 28)
        }
    }
}

/// Attach to any screen with a sign-out control.
private struct SignOutWarningOverlay: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                SignOutWarningModal(
                    onSignOut: {
                        withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
                        onConfirm()
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(99)
            }
        }
    }
}

extension View {
    func signOutWarning(_ isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        modifier(SignOutWarningOverlay(isPresented: isPresented, onConfirm: onConfirm))
    }
}
