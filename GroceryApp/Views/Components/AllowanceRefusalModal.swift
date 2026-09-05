import SwiftUI

/// What a closed gate says. One shape for every allowance, so the message reads
/// the same wherever it appears: what ran out, when it comes back, and the way
/// to the plan page — which is where subscribing will live.
struct AllowanceRefusal: Identifiable {
    enum Kind { case imports, placements, items }

    let kind: Kind
    /// An action the person may still take — "Shop anyway" when placements are
    /// out, because the trip is never blocked, only the sorting.
    var proceed: (label: String, action: () -> Void)? = nil
    /// Run when the card is dismissed without proceeding — clearing a store
    /// selection, say.
    var cancel: (() -> Void)? = nil

    var id: String {
        switch kind {
        case .imports: return "imports"
        case .placements: return "placements"
        case .items: return "items"
        }
    }

    var title: String {
        switch kind {
        case .imports: return "Out of imports"
        case .placements: return "Out of aisle placements"
        case .items: return "The list is full"
        }
    }

    /// Numbers come from the server's summary, never a literal.
    @MainActor var message: String {
        let s = AllowanceService.shared.summary
        let days = s?.daysUntilReset ?? 0
        let reset = "Resets in \(days) day\(days == 1 ? "" : "s")."
        switch kind {
        case .imports: return "All \(s?.parsesCap ?? 0) used this period. \(reset)"
        case .placements: return "All \(s?.placementsCap ?? 0) used this period. This trip shops unsorted. \(reset)"
        case .items: return "\(s?.itemsCap ?? 0) items is the most a free household holds. Delete a few to add more."
        }
    }
}

/// The card. Same construction as the allowance and shopping modals.
struct AllowanceRefusalModal: View {
    let refusal: AllowanceRefusal
    /// Hidden while shopping — the one rule the doc calls an invariant, enforced
    /// here rather than at each call site.
    let showPlanLink: Bool
    let onSeePlan: () -> Void
    let onDismiss: () -> Void

    private let accent = DesignSystem.Colors.neonAmber

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { }

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(accent)
                }

                Text(refusal.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(refusal.message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)

                if let proceed = refusal.proceed {
                    primaryButton(proceed.label) {
                        onDismiss()
                        proceed.action()
                    }
                } else if showPlanLink {
                    primaryButton("See plan", action: onSeePlan)
                }

                if refusal.proceed != nil, showPlanLink {
                    Button("See plan", action: onSeePlan)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(accent)
                }

                Button(refusal.proceed != nil ? "Cancel" : "OK", action: onDismiss)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(28)
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
            .padding(.horizontal, 32)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [accent, accent.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .shadow(color: accent.opacity(0.4), radius: 8, x: 0, y: 4)
                )
        }
        .padding(.top, 4)
    }
}

/// Attach to any screen that can close a gate. Owns the plan sheet, so "See
/// plan" works from inside another sheet as well as from the main list.
private struct AllowanceRefusalOverlay: ViewModifier {
    @Binding var refusal: AllowanceRefusal?
    let viewModel: ShoppingListViewModel
    @State private var showPlan = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if let refusal {
                    AllowanceRefusalModal(
                        refusal: refusal,
                        showPlanLink: viewModel.shoppingStatus != .atStore,
                        onSeePlan: {
                            withAnimation(.easeOut(duration: 0.2)) { self.refusal = nil }
                            showPlan = true
                        },
                        onDismiss: {
                            let cancel = refusal.cancel
                            withAnimation(.easeOut(duration: 0.2)) { self.refusal = nil }
                            cancel?()
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(99)
                }
            }
            .sheet(isPresented: $showPlan) {
                AllowancesView()
                    .environmentObject(viewModel)
            }
    }
}

extension View {
    func allowanceRefusal(_ refusal: Binding<AllowanceRefusal?>, viewModel: ShoppingListViewModel) -> some View {
        modifier(AllowanceRefusalOverlay(refusal: refusal, viewModel: viewModel))
    }
}

#Preview("Imports") {
    AllowanceRefusalModal(refusal: AllowanceRefusal(kind: .imports), showPlanLink: true, onSeePlan: {}, onDismiss: {})
}

#Preview("Placements, can proceed") {
    AllowanceRefusalModal(
        refusal: AllowanceRefusal(kind: .placements, proceed: (label: "Shop anyway", action: {})),
        showPlanLink: true, onSeePlan: {}, onDismiss: {}
    )
}
