import SwiftUI

/// This account was signed in somewhere else, so this phone stands down.
///
/// Not a choice — the account has already moved and nothing here can bring it
/// back. What the screen is actually for is the work this phone was still
/// holding: anything queued offline is about to become unreachable, and the
/// person deserves to see what it was before it goes.
struct DeviceSupersededModal: View {
    let otherDeviceName: String
    /// Names of changes that could not be sent, empty when everything drained.
    let stuck: [String]
    let isFlushing: Bool
    let onSignOut: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 44))
                    .foregroundColor(DesignSystem.Colors.neonAmber)

                Text("Signed in on \(otherDeviceName)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Got Dill? works on one phone at a time, so this one has signed out. Your list is safe — it's on the server and on \(otherDeviceName).")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if isFlushing {
                    HStack(spacing: 8) {
                        ProgressView().tint(DesignSystem.Colors.dillGreen)
                        Text("Sending what this phone still had…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                } else if !stuck.isEmpty {
                    // The only part worth reading twice. Named, because "some
                    // changes were lost" is not something anybody can act on.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stuck.count == 1
                             ? "This change never reached the server and will be lost:"
                             : "These \(stuck.count) changes never reached the server and will be lost:")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.neonAmber)
                        ForEach(stuck.prefix(6), id: \.self) { name in
                            Text("• \(name)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                        }
                        if stuck.count > 6 {
                            Text("• and \(stuck.count - 6) more")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.neonAmber.opacity(0.12))
                    )
                }

                Button(action: onSignOut) {
                    Text(stuck.isEmpty ? "OK" : "Sign out anyway")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(DesignSystem.Colors.accentGradient)
                        )
                }
                .disabled(isFlushing)
                .opacity(isFlushing ? 0.5 : 1)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(DesignSystem.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(DesignSystem.Colors.neonAmber.opacity(0.4), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 28)
        }
    }
}
