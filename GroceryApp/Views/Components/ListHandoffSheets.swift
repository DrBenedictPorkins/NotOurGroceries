import SwiftUI

/// Holding the list up for someone else's phone.
///
/// One square, the count, and nothing else. There is no send button and nothing
/// leaves this phone: the other camera does all the work, so this screen is over
/// when the guest looks up.
struct ShareListQRSheet: View {
    let names: [String]
    @Binding var isPresented: Bool

    /// What actually fits in the square, after trimming and de-duplication.
    private var sending: [String] { Array(ListHandoff.prepare(names).prefix(ListHandoff.maxItems)) }
    private var dropped: Int { max(0, ListHandoff.prepare(names).count - ListHandoff.maxItems) }

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

                VStack(spacing: 22) {
                    Spacer(minLength: 0)

                    QRSquare(
                        payload: ListHandoff.encode(sending),
                        size: 240,
                        // Nothing to damage in ten seconds on a screen, so the
                        // spare capacity goes to a smaller, faster square.
                        correctionLevel: "L"
                    )
                    .accessibilityLabel("\(sending.count) items as a QR square")

                    VStack(spacing: 6) {
                        Text(sending.count == 1 ? "1 item" : "\(sending.count) items")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.textPrimary)

                        Text("On their phone: tap the list title, then Scan a list.")
                            .font(.system(size: 13))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                    }

                    // Said plainly rather than shown as a trimmed square that
                    // looks complete. Anything cut has to be cut out loud.
                    if dropped > 0 {
                        Text("\(dropped) more \(dropped == 1 ? "item is" : "items are") not in this code. A square only holds \(ListHandoff.maxItems).")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.neonAmber)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(DesignSystem.Colors.neonAmber.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(DesignSystem.Colors.neonAmber.opacity(0.35), lineWidth: 1)
                                    )
                            )
                    }

                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .navigationTitle("Hand over the list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

/// Taking a list off someone else's phone.
///
/// The camera runs until it reads one of our squares, then stops and asks before
/// writing anything. A scan is not consent — pointing a camera is too easy to do
/// by accident for the items to just appear.
struct ReceiveListSheet: View {
    @Binding var isPresented: Bool
    /// Handed the names once the person confirms. Nothing is written here.
    let onAccept: ([String]) -> Void

    private enum Stage: Equatable {
        case scanning
        case found([String])
        case notAList
    }

    @State private var stage: Stage = .scanning

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()

                switch stage {
                case .scanning:
                    QRScanner { scanned in
                        guard stage == .scanning else { return }
                        if let names = ListHandoff.decode(scanned) {
                            stage = .found(names)
                        } else {
                            stage = .notAList
                        }
                    }
                    .ignoresSafeArea()

                case .found(let names):
                    confirm(names)

                case .notAList:
                    message(
                        icon: "questionmark.square.dashed",
                        title: "That isn't a shopping list",
                        detail: "It scanned, but it wasn't a list from \(AppIdentity.name) Ask them to tap the list title and choose Show the list."
                    )
                }
            }
            .navigationTitle(stage == .scanning ? "Scan a list" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    private func confirm(_ names: [String]) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.neonPurple)
                .frame(width: 78, height: 78)
                .background(Circle().fill(DesignSystem.Colors.neonPurple.opacity(0.14)))

            Text(names.count == 1 ? "1 item" : "\(names.count) items")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Text("Goes to your Quick Trip. It stays on this phone, nobody in your household sees it, and it never becomes a suggestion.")
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(names, id: \.self) { name in
                        Text("· \(name)")
                            .font(.system(size: 14))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onAccept(names)
                isPresented = false
            } label: {
                Text("Add to Quick Trip")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(DesignSystem.Colors.neonPurple)
                    )
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.neonAmber)

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)

            Button("Try again") { stage = .scanning }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.neonPurple)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(28)
    }
}
