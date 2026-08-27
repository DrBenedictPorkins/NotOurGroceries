import SwiftUI

/// Persistent "you are on paper" banner. Deliberately not dismissible: the user
/// must never wonder which mode they're in, and must never believe the rest of
/// the household can see what they're doing.
struct PaperModeBanner: View {
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject private var paperMode = PaperMode.shared

    var onReconnect: () -> Void

    private var accent: Color { DesignSystem.Colors.neonYellow }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext.fill")
                    .font(.system(size: 13, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Paper list · not syncing")
                        .font(.system(size: 12.5, weight: .bold))
                    Text(savedAtLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }

                Spacer()
            }

            // The gentle offer. Only appears once the network actually looks
            // usable again — and it says what's waiting, not "sync available".
            if paperMode.networkLooksBack {
                Button(action: onReconnect) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back online — reconnect and check for new items")
                            .font(.system(size: 12, weight: .semibold))
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(DesignSystem.Colors.neonCyan.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(DesignSystem.Colors.neonCyan.opacity(0.4), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundColor(accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
        )
        .animation(.easeInOut(duration: 0.25), value: paperMode.networkLooksBack)
    }

    private var savedAtLine: String {
        guard let savedAt = viewModel.localSnapshotSavedAt else {
            return "Changes stay on this phone"
        }
        return "Your list as of \(LocalListStore.savedAtDescription(savedAt)) · changes stay on this phone"
    }
}
