import SwiftUI

/// A store-less errand: "run to the Japanese deli for a few things".
///
/// Deliberately not AtStoreModeView with the store bits hidden — there is no store,
/// so there are no aisles, no aisle inference, no store switcher, and no request inbox.
/// It is styled purple throughout so it can never be mistaken for the main list, which
/// stays untouched underneath and is restored when the trip ends.
struct AdHocModeView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @State private var searchText = ""
    @State private var showFinishAlert = false
    @State private var isSuggestionsExpanded = true
    @State private var isMainListExpanded = true
    @FocusState private var searchFieldFocused: Bool

    private var accent: Color { DesignSystem.Colors.neonPurple }

    private var remaining: Int { viewModel.adHocList.count }
    private var grabbed: Int { viewModel.adHocInCart.count }
    private var total: Int { remaining + grabbed }

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            // Purple wash so the whole screen reads differently from the main list
            accent.opacity(0.06)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerView

                List {
                    Section {
                        SearchBar(
                            text: $searchText,
                            isFocused: $searchFieldFocused,
                            onSubmit: addItemFromSearch,
                            onProductSelected: addProductFromSearch,
                            onImport: nil
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))

                    // To grab
                    Section {
                        if viewModel.adHocList.isEmpty {
                            emptyStateView
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        } else {
                            ForEach(viewModel.adHocList) { item in
                                GroceryItemRow(item: item)
                                    .environmentObject(viewModel)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            }
                            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.adHocList.map(\.id))
                        }
                    }
                    .listSectionSeparator(.hidden)

                    // Grabbed
                    if !viewModel.adHocInCart.isEmpty {
                        Section {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("IN BAG (\(grabbed))")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.5)
                            }
                            .foregroundColor(accent)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))

                            ForEach(viewModel.adHocInCart) { item in
                                GroceryItemRow(item: item)
                                    .environmentObject(viewModel)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            }
                            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.adHocInCart.map(\.id))
                        }
                        .listSectionSeparator(.hidden)
                    }

                    // The main list, right there. Quick Trip used to hide it,
                    // which made "errand plus grab a few things" — the most
                    // common real trip — impossible without leaving the mode.
                    if !viewModel.shoppingList.isEmpty {
                        Section {
                            HStack(spacing: 6) {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        isMainListExpanded.toggle()
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "list.bullet")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("SHOPPING LIST (\(viewModel.shoppingList.count))")
                                            .font(.system(size: 12, weight: .bold))
                                            .tracking(0.5)
                                        Image(systemName: isMainListExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundColor(DesignSystem.Colors.neonCyan)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                // For when the trip turns into "actually, let me
                                // just do the whole shop while I'm here".
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    Task {
                                        for item in viewModel.shoppingList {
                                            await viewModel.pullItemToAdHoc(item)
                                        }
                                    }
                                } label: {
                                    Text("Add all")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(DesignSystem.Colors.neonCyan)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(DesignSystem.Colors.neonCyan.opacity(0.12))
                                                .overlay(Capsule().stroke(DesignSystem.Colors.neonCyan.opacity(0.4), lineWidth: 1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))

                            if isMainListExpanded {
                                ForEach(viewModel.shoppingList) { item in
                                    GroceryItemRow(item: item)
                                        .environmentObject(viewModel)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                }
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }

                    // Suggestions, exactly as they appear on the main list —
                    // tapping one adds it to this trip.
                    if !viewModel.suggestions.isEmpty {
                        Section {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    isSuggestionsExpanded.toggle()
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lightbulb.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("SUGGESTIONS (\(viewModel.suggestions.count))")
                                        .font(.system(size: 12, weight: .bold))
                                        .tracking(0.5)
                                    Spacer()
                                    Image(systemName: isSuggestionsExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(DesignSystem.Colors.neonYellow)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))

                            if isSuggestionsExpanded {
                                ForEach(viewModel.suggestions) { item in
                                    GroceryItemRow(item: item)
                                        .environmentObject(viewModel)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                }
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            // Dashed purple border — the persistent "you are on an errand" cue
            errandBorderOverlay
        }
        .navigationBarHidden(true)
        .onChange(of: viewModel.isAdHocMode) { _, stillOnTrip in
            // Empty cancel produces no completion sheet, so nothing else would
            // take us back to the list.
            if !stillOnTrip && !viewModel.showShoppingCompletedSheet {
                isPresented = false
            }
        }
        .sheet(isPresented: $viewModel.showShoppingCompletedSheet) {
            if let stats = viewModel.shoppingCompletionStats {
                ShoppingCompletedSheet(stats: stats) {
                    viewModel.showShoppingCompletedSheet = false
                    viewModel.shoppingCompletionStats = nil
                    isPresented = false
                }
                .interactiveDismissDisabled()
            }
        }
        .alert("Finish this trip?", isPresented: $showFinishAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Finish", role: .destructive) {
                Task { await viewModel.exitAdHocMode() }
            }
        } message: {
            Text(finishSummary)
        }
    }

    /// Spells out exactly what finishing will do, since the outcome differs per item.
    private var finishSummary: String {
        let pulled = viewModel.adHocList.filter(\.adHocPulled).count
        let fresh = viewModel.adHocList.filter { !$0.adHocPulled }.count

        var parts: [String] = []
        if grabbed > 0 {
            parts.append("\(grabbed) item\(grabbed == 1 ? "" : "s") you picked up will be saved as suggestions.")
        }
        if pulled > 0 {
            parts.append("\(pulled) item\(pulled == 1 ? "" : "s") pulled from the main list will go back to it.")
        }
        if fresh > 0 {
            parts.append("\(fresh) unbought item\(fresh == 1 ? "" : "s") added just for this trip will be discarded.")
        }
        if parts.isEmpty {
            return "Nothing on this trip yet — finishing just returns you to the main list."
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(accent)
                        Text("Quick Trip")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(accent)
                    }

                    Text(total == 0
                         ? "No store — just what you need right now"
                         : "\(grabbed) of \(total) picked up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if total == 0 {
                        // Nothing happened, so there's nothing to confirm or
                        // report — finishing an empty trip is just backing out.
                        Task { await viewModel.exitAdHocMode() }
                    } else {
                        showFinishAlert = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: total == 0 ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(total == 0 ? "Cancel" : "Finish")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(accent.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(accent, lineWidth: 1.5)
                            )
                            .shadow(color: DesignSystem.Shadows.neonPurpleGlow, radius: 8, x: 0, y: 4)
                    )
                }
            }

            // The reassurance the user explicitly asked for
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Your main list is untouched and comes back when you finish")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(accent.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(accent.opacity(0.1))
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 10)
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "bag")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(accent.opacity(0.5))
            Text("Nothing on this trip yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Text("Search above, or tap something from your list below")
                .font(.system(size: 12))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Inset and corner-radiused to match the display, so the dashes sit evenly
    /// inside the screen instead of being clipped by its rounded corners.
    private var errandBorderOverlay: some View {
        RoundedRectangle(cornerRadius: 46, style: .continuous)
            .strokeBorder(
                accent.opacity(0.6),
                style: StrokeStyle(lineWidth: 3, dash: [9, 7], dashPhase: 0)
            )
            .padding(3)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func addItemFromSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await viewModel.addItem(name: trimmed)
            searchText = ""
        }
    }

    private func addProductFromSearch(_ product: Product) {
        Task {
            await viewModel.addItem(name: product.name, productId: product.id)
            searchText = ""
        }
    }
}
