import SwiftUI

/// Paper List mode, rendered as a piece of paper.
///
/// The banner-on-the-normal-list version failed the only test that matters: at a
/// glance it looked exactly like the connected app, so there was nothing to tell
/// you the household could not see what you were doing. This is deliberately a
/// different object — cream stock, ruled lines, a red margin, dark ink — so the
/// mode is obvious from across a shopping aisle.
///
/// Its palette is fixed and ignores light/dark mode. Paper is paper.
struct PaperListView: View {
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject private var paperMode = PaperMode.shared

    var onReconnect: () -> Void

    // MARK: - Paper palette

    private enum Paper {
        static let stock      = Color(red: 0.988, green: 0.969, blue: 0.902)  // legal-pad cream
        static let rule       = Color(red: 0.741, green: 0.808, blue: 0.878)  // faint blue rule
        static let margin     = Color(red: 0.839, green: 0.416, blue: 0.416)  // red margin line
        static let ink        = Color(red: 0.122, green: 0.114, blue: 0.098)
        static let inkFaded   = Color(red: 0.122, green: 0.114, blue: 0.098).opacity(0.40)
        static let pencil     = Color(red: 0.35, green: 0.36, blue: 0.34)
    }

    private static let rowHeight: CGFloat = 44
    private static let marginX: CGFloat = 52

    /// One flat list, in the order it was written. Deliberately not split into
    /// sections and deliberately not re-sorted when something is ticked — on
    /// paper, a crossed-off line stays exactly where it was written.
    private var lines: [GroceryItem] {
        viewModel.items.filter { item in
            let s: GroceryItem.ItemStatus = item.status
            return s == .active || s == .inCart
        }
    }

    var body: some View {
        ZStack {
            Paper.stock.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if lines.isEmpty {
                    emptySheet
                } else {
                    ruledList
                }
            }
        }
        // Paper is a light object regardless of the phone's appearance setting.
        .environment(\.colorScheme, .light)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shopping list")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundColor(Paper.ink)

                Spacer()

                Text("\(remainingCount) left")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundColor(Paper.pencil)
            }

            Text(savedAtLine)
                .font(.system(size: 12, weight: .regular, design: .serif))
                .foregroundColor(Paper.pencil)

            if paperMode.networkLooksBack {
                Button(action: onReconnect) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi")
                        Text("Back online — reconnect and check for new items")
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 12.5, weight: .semibold, design: .serif))
                    .foregroundColor(Paper.margin)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Paper.margin.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.25), value: paperMode.networkLooksBack)
    }

    // MARK: - The sheet

    private var ruledList: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Red margin, drawn the full height of the written area.
                Rectangle()
                    .fill(Paper.margin.opacity(0.55))
                    .frame(width: 1)
                    .offset(x: Self.marginX)

                LazyVStack(spacing: 0) {
                    ForEach(lines) { item in
                        line(for: item)
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func line(for item: GroceryItem) -> some View {
        let isChecked = item.status == .inCart

        return Button {
            toggle(item)
        } label: {
            HStack(spacing: 0) {
                // Checkbox sits in the margin, where you'd tick a real list.
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(isChecked ? Paper.pencil : Paper.ink.opacity(0.55))
                    .frame(width: Self.marginX, alignment: .center)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .strikethrough(isChecked, color: Paper.pencil)
                        .foregroundColor(isChecked ? Paper.inkFaded : Paper.ink)

                    if let quantity = item.quantity, !quantity.isEmpty {
                        Text(quantity)
                            .font(.system(size: 14, weight: .regular, design: .serif))
                            .strikethrough(isChecked, color: Paper.pencil)
                            .foregroundColor(Paper.pencil.opacity(isChecked ? 0.5 : 0.9))
                    }

                    Spacer(minLength: 8)
                }
                .padding(.trailing, 20)
            }
            .frame(height: Self.rowHeight, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Paper.rule)
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isChecked)
    }

    private var emptySheet: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Nothing on the list")
                .font(.system(size: 18, weight: .regular, design: .serif))
                .foregroundColor(Paper.pencil)
            Text("You switched to paper with an empty list.")
                .font(.system(size: 13, weight: .regular, design: .serif))
                .foregroundColor(Paper.pencil.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Behaviour

    private var remainingCount: Int {
        lines.filter { $0.status == .active }.count
    }

    /// Ticking a line moves it between ACTIVE and IN_CART, exactly as it would
    /// online — so reconnecting later replays a normal shopping trip rather than
    /// some paper-only state the rest of the app would not understand. The row
    /// does not move; only its appearance changes.
    private func toggle(_ item: GroceryItem) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            if item.status == .inCart {
                await viewModel.restoreItem(item)
            } else {
                await viewModel.moveToCart(item)
            }
        }
    }

    private var savedAtLine: String {
        guard let savedAt = viewModel.localSnapshotSavedAt else {
            return "Not syncing · changes stay on this phone"
        }
        return "As of \(LocalListStore.savedAtDescription(savedAt)) · not syncing"
    }
}
