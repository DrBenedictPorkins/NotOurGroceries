import SwiftUI

/// The way out when a change simply will not save.
///
/// The outbox exists so that work done offline is not clobbered by the server's
/// older copy. That is right until a change is one the server will *never*
/// accept — and then the queue never drains and the list quietly stops matching
/// what everybody else sees.
///
/// The app used to have no answer to that at all. It kept retrying, kept refusing
/// to publish, and said nothing, so the only fix was reinstalling. This is the
/// answer: say plainly what cannot be saved, name it, and offer to throw it away
/// and take the server's copy. Losing two items you know about beats a list that
/// silently lies for a day and a half.
struct SyncStuckModal: View {
    /// The items that will be lost, by name. Named rather than counted, because
    /// "2 changes" is not something anybody can make a decision about.
    let stuckNames: [String]
    let onDiscardAndReload: () -> Void
    let onKeepTrying: () -> Void

    private let accent = DesignSystem.Colors.neonAmber

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea().onTapGesture { }

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(accent.opacity(0.15)).frame(width: 76, height: 76)
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(accent)
                }

                Text("Your list is out of date")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(stuckNames.count == 1
                     ? "One change cannot be saved, and until it is sorted out this phone is not seeing what anyone else adds."
                     : "\(stuckNames.count) changes cannot be saved, and until they are sorted out this phone is not seeing what anyone else adds.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stuckNames.prefix(6), id: \.self) { name in
                        Text("· \(name)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if stuckNames.count > 6 {
                        Text("and \(stuckNames.count - 6) more")
                            .font(.system(size: 13))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.32), lineWidth: 1))
                )

                Text("Discarding throws those away and reloads the list everyone else can see. Nothing else on the list is affected.")
                    .font(.system(size: 13))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDiscardAndReload()
                } label: {
                    Text("Discard and reload")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LinearGradient(colors: [accent, accent.opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                }
                .padding(.top, 2)

                Button("Keep trying", action: onKeepTrying)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(26)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(DesignSystem.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(LinearGradient(colors: [accent.opacity(0.5), accent.opacity(0.2)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                    )
                    .shadow(color: accent.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 28)
        }
    }
}
