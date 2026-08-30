import SwiftUI

/// What opens when you tap the list title: how you want to shop. Nothing else.
///
/// It used to also carry your name and avatar, the version and build, and a Sign
/// Out button — which made it a second, worse copy of the Settings tab. All of
/// that still lives in Settings, where someone looking for it would go. You tap
/// the list title to pick a mode, so a mode is all this offers.
struct ListMenuSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject private var stats = TripStats.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flipped once, on appear, to drive the count-up. Kept as state rather than
    /// animating the real values so reopening the sheet replays it.
    @State private var revealed = false
    /// Drives the empty-state demo: sample figures first, then they fade and the
    /// card says what it is.
    @State private var demoFaded = false
    /// One-shot: drives the light sweep across the sample figures.
    @State private var sheenSwept = false
    @State private var showTrackRecord = false
    @State private var showRestoreConfirmation = false
    var onAtStore: () -> Void
    var onQuickList: () -> Void

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

            ScrollView {
                VStack(spacing: 18) {
                    section("Start shopping") {
                        row(
                            icon: "cart.fill",
                            tint: DesignSystem.Colors.dillGreen,
                            title: "At Store",
                            detail: viewModel.shoppingList.isEmpty
                                ? "Add something to the list first."
                                : "Full trip, sorted by aisle. Everyone sees you're shopping.",
                            disabled: !canStartShopping
                        ) {
                            isPresented = false
                            onAtStore()
                        }

                        row(
                            icon: "list.bullet.rectangle.portrait",
                            tint: DesignSystem.Colors.neonPurple,
                            title: "Quick Trip",
                            detail: "Scratch list for a quick errand. This phone only — never shared.",
                            disabled: false
                        ) {
                            isPresented = false
                            onQuickList()
                        }
                    }

                    restoreSection

                    trackRecord

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showTrackRecord) {
            TrackRecordView(isPresented: $showTrackRecord)
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Restore

    /// Finishing a trip sweeps the list into suggestions. Once in a while that
    /// is the wrong outcome — the trip that got cut short, the one finished at
    /// the wrong store — and every name is still on this phone, so putting it
    /// back is a tap.
    ///
    /// Only offered when there is a trip that kept its item names, and only
    /// while nobody is mid-session: restoring under a shopper's feet would add
    /// rows to a list they are actively working.
    @ViewBuilder
    private var restoreSection: some View {
        if isIdle, let trip = TripStats.shared.restorableTrip {
            section("Start over") {
                row(
                    icon: "arrow.uturn.backward",
                    tint: DesignSystem.Colors.neonAmber,
                    title: "Restore last trip",
                    detail: restoreDetail(trip),
                    disabled: false
                ) {
                    showRestoreConfirmation = true
                }
            }
            .confirmationDialog(
                "Restore that list?",
                isPresented: $showRestoreConfirmation,
                titleVisibility: .visible
            ) {
                Button("Put it back") {
                    isPresented = false
                    Task { await viewModel.restoreLastTrip() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Adds the \(trip.everythingOnTheList.count) items from \(trip.storeName) back to the list. Anything already there is left alone.")
            }
        }
    }

    private func restoreDetail(_ trip: TripRecord) -> String {
        let count = trip.everythingOnTheList.count
        let items = count == 1 ? "1 item" : "\(count) items"

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: trip.endedAt, relativeTo: Date())

        return "\(items) from \(trip.storeName), \(when)."
    }

    // MARK: - Track record

    /// Secondary by design — you opened this to pick a mode, and this sits under
    /// the two rows that do that.
    ///
    /// Every figure is counted from a trip this phone actually watched finish.
    /// Nothing is estimated or backfilled, so a phone with no finished trips
    /// says exactly that instead of showing a number that looks like history.
    @ViewBuilder
    private var trackRecord: some View {
        section("Your track record", tag: "on this phone") {
            if stats.hasAnything {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        figure(stats.tripCount, "trips", delay: 0)
                        divider
                        figure(stats.itemsPickedUp, "items", delay: 0.08)
                        divider
                        figure(stats.quickTripCount, "quick", delay: 0.16)
                    }
                    .padding(.vertical, 18)

                    if let footnote {
                        Rectangle()
                            .fill(DesignSystem.Colors.glassBorder)
                            .frame(height: 1)

                        Text(footnote)
                            .font(.system(size: 12))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(card)
                .transition(.opacity)
                .contentShape(Rectangle())
                .onTapGesture { showTrackRecord = true }
                .onAppear {
                    // A hair after present, so the sheet has settled and the
                    // count reads as the panel arriving rather than a glitch.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        revealed = true
                    }
                }
            } else {
                exampleCard
            }
        }
        .animation(.easeInOut(duration: 0.8), value: stats.hasAnything)
    }

    /// The empty state, played as a short demo: sample figures count in, hold,
    /// then fade out and the card says what it is.
    ///
    /// The numbers are invented, so the card does not leave them standing. They
    /// are flat and faint — the real figures carry the gradient — they rise into
    /// focus, hold, then dissolve upward and hand the card to a line that says
    /// there is no data yet. Sequenced, not omitted: the demo shows the shape,
    /// the message tells you it was a demo.
    private var exampleCard: some View {
        ZStack {
            HStack(spacing: 0) {
                exampleFigure(12, "trips", delay: 0)
                divider
                exampleFigure(184, "items", delay: 0.14)
                divider
                exampleFigure(5, "quick", delay: 0.28)
            }
            .padding(.vertical, 18)
            // The row leaves as one piece — drifting up and out of focus — so it
            // reads as making way for the message rather than being switched off.
            .opacity(demoFaded ? 0 : 1)
            .offset(y: demoFaded ? -14 : 0)
            .blur(radius: demoFaded ? 7 : 0)
            .overlay(sheen)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.85), value: demoFaded)

            Text("Nothing counted yet — this is how your trips will show up once you finish one.")
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .opacity(demoFaded ? 1 : 0)
                .offset(y: demoFaded ? 0 : 12)
                .blur(radius: demoFaded ? 0 : 4)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.8).delay(0.35),
                    value: demoFaded
                )
        }
        .frame(maxWidth: .infinity)
        .background(card)
        .transition(.opacity)
        .onAppear {
            // Reduce Motion drops the count-up, not the demo. Skipping straight
            // to the message meant anyone with the setting on never saw what the
            // card is for.
            if reduceMotion {
                revealed = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { revealed = true }
            }

            // One pass of light across the figures, once they have landed.
            if !reduceMotion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                    withAnimation(.easeInOut(duration: 1.25)) { sheenSwept = true }
                }
            }

            // Long enough to read the shape and watch it settle, short enough
            // that nobody walks away believing the numbers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                demoFaded = true
            }
        }
    }

    /// Flat and faint on purpose — no gradient. The real figures get one, so a
    /// filled card never looks like this.
    ///
    /// Rises out of a blur while the digits decelerate into place. `easeOut`
    /// rather than a spring: a spring overshoots, and an overshooting counter
    /// runs past its target and walks back, which reads as a glitch.
    private func exampleFigure(_ value: Int, _ label: String, delay: Double) -> some View {
        VStack(spacing: 4) {
            RollingNumber(value: revealed ? Double(value) : 0)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.45))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 16)
        .blur(radius: revealed ? 0 : 8)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 1.15).delay(delay),
            value: revealed
        )
    }

    /// A single pass of light over the figures. Masked to the row, so it lights
    /// the digits rather than painting a band across the card.
    private var sheen: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.28), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: geo.size.width * 0.45)
            .rotationEffect(.degrees(18))
            .offset(x: sheenSwept ? geo.size.width * 1.1 : -geo.size.width * 0.6)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .clipped()
    }

    private func figure(_ value: Int, _ label: String, delay: Double) -> some View {
        VStack(spacing: 4) {
            RollingNumber(value: (revealed || reduceMotion) ? Double(value) : 0)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .opacity(revealed || reduceMotion ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 8)
        .animation(
            reduceMotion ? nil : .spring(response: 0.85, dampingFraction: 0.82).delay(delay),
            value: revealed
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignSystem.Colors.glassBorder)
            .frame(width: 1, height: 34)
    }

    /// Only says what it can back up: the store dropped if no trip has named one,
    /// the average dropped if no trip has been timed.
    private var footnote: String? {
        var parts: [String] = []
        if let store = stats.favouriteStore { parts.append("Mostly \(store)") }
        if let minutes = stats.averageMinutes { parts.append("about \(minutes) min a trip") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Counts from wherever it is to wherever it is told to go.
    ///
    /// A `View` that is also `Animatable`: SwiftUI interpolates `animatableData`
    /// frame by frame and rebuilds the body each time, which is the only way to
    /// animate a number that is being formatted into a string.
    private struct RollingNumber: View, Animatable {
        var value: Double

        var animatableData: Double {
            get { value }
            set { value = newValue }
        }

        var body: some View {
            Text("\(Int(value.rounded()))")
        }
    }

    /// Nobody is out shopping. The condition for touching the list at all.
    private var isIdle: Bool {
        viewModel.shoppingStatus == .idle
    }

    /// At Store also needs a list, since the whole mode is walking one.
    private var canStartShopping: Bool {
        isIdle && !viewModel.shoppingList.isEmpty
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        tag: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                if let tag {
                    Text(tag.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.9)
                        .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                                .overlay(Capsule().stroke(DesignSystem.Colors.glassBorder, lineWidth: 1))
                        )
                }

                Spacer(minLength: 0)
            }
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

    private var card: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
    }

}
