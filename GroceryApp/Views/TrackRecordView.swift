import SwiftUI
import Charts

/// Everything this phone has counted, in one place.
///
/// Opened from the summary card in the list menu, which stays deliberately
/// small — three numbers and a footnote. This is where the detail goes so that
/// panel does not turn back into a settings screen.
///
/// Every section is drawn from recorded trips and disappears when it has nothing
/// to say. Nothing is estimated, projected, or filled in with a placeholder: a
/// chart with two bars shows two bars.
struct TrackRecordView: View {
    @ObservedObject private var stats = TripStats.shared
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

            ScrollView {
                VStack(spacing: 18) {
                    headline
                    if !stats.tripsByWeek().isEmpty { weeklyChart }
                    if !stats.topItems().isEmpty { topItemsCard }
                    if stats.tripCount > 0 { recordsCard }
                    if stats.storeBreakdown.count > 1 { storesCard }
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var closeButton: some View {
        Button { isPresented = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .padding(.top, 14)
        .padding(.trailing, 18)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Track record")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                tag("on this phone")
                Spacer(minLength: 0)
            }

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)   // clears the close button
    }

    private var subtitle: String {
        guard let first = stats.trips.first else {
            return "Counted here, never sent anywhere."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return "Since \(formatter.string(from: first.endedAt)) · counted here, never sent anywhere."
    }

    // MARK: - Weekly chart

    private var weeklyChart: some View {
        card(title: "Trips a week") {
            Chart(stats.tripsByWeek(), id: \.weekStart) { week in
                BarMark(
                    x: .value("Week", week.weekStart, unit: .weekOfYear),
                    y: .value("Trips", week.trips)
                )
                .foregroundStyle(DesignSystem.Colors.dillGreen.gradient)
                .cornerRadius(4)
            }
            .chartYAxis {
                // Trips are whole numbers; the default axis invents halves.
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(DesignSystem.Colors.glassBorder)
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text("\(count)")
                                .font(.system(size: 10))
                                .foregroundColor(DesignSystem.Colors.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Top items

    private var topItemsCard: some View {
        card(title: "What you actually buy") {
            let items = stats.topItems()
            let most = items.first?.count ?? 1

            VStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.name) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                            .frame(width: 14, alignment: .trailing)

                        Text(item.name)
                            .font(.system(size: 15))
                            .foregroundColor(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        // Bar length is relative to the top item, so the shape
                        // of the list is readable at a glance.
                        GeometryReader { geo in
                            Capsule()
                                .fill(DesignSystem.Colors.dillGreen.opacity(0.55))
                                .frame(width: max(4, geo.size.width * (Double(item.count) / Double(most))))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: 70, height: 8)

                        Text("\(item.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Records

    private var recordsCard: some View {
        card(title: "Records") {
            VStack(spacing: 12) {
                if let minutes = stats.averageMinutes {
                    line("Average trip", "\(minutes) min")
                }
                if let longest = stats.longestTrip {
                    line("Longest", "\(longest.minutes) min at \(longest.storeName)")
                }
                if let shortest = stats.shortestTrip, stats.tripCount > 1 {
                    line("Quickest", "\(shortest.minutes) min at \(shortest.storeName)")
                }
                if let biggest = stats.biggestHaul {
                    line("Biggest haul", "\(biggest.itemsPickedUp) items at \(biggest.storeName)")
                }
                if let left = stats.totalLeftBehind {
                    line("Left behind", left == 1 ? "1 item" : "\(left) items")
                }
                if !stats.quickRuns.isEmpty {
                    let picked = stats.quickRuns.reduce(0) { $0 + $1.picked }
                    line("Quick trips", "\(stats.quickTripCount) · \(picked) ticked off")
                }
            }
        }
    }

    // MARK: - Stores

    private var storesCard: some View {
        card(title: "Where you shop") {
            VStack(spacing: 10) {
                ForEach(stats.storeBreakdown, id: \.store) { entry in
                    line(entry.store, entry.trips == 1 ? "1 trip" : "\(entry.trips) trips")
                }
            }
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundColor(DesignSystem.Colors.textTertiary)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                )
        )
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text.uppercased())
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
}
