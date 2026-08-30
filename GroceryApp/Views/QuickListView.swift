import SwiftUI

/// "Honey, what do I need?" — a scratch list, on this phone only.
///
/// Everything about it is deliberately narrower than the main list: no store, no
/// aisles, no suggestions, no sync, no history. It is one column of text you can
/// tick. The earlier version failed because it looked like the main list and
/// borrowed its items; this one is a separate list that happens to sit next to
/// them, and nothing you do here reaches the household.
struct QuickListView: View {
    @ObservedObject private var store = QuickListStore.shared
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @Binding var isPresented: Bool

    @State private var entry = ""
    @FocusState private var entryFocused: Bool
    @State private var showClearConfirmation = false
    @State private var showDoneConfirmation = false
    @State private var showImport = false
    @State private var mainListExpanded = false

    var body: some View {
        ZStack {
            DesignSystem.Colors.secondaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                entryField

                if store.isEmpty {
                    empty
                } else {
                    list
                }

                mainListReference
                suggestionsStrip
            }
        }
        .sheet(isPresented: $showImport) {
            BulkImportSheet(isPresented: $showImport) { names in
                store.add(contentsOf: names)
            }
            .environmentObject(viewModel)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Trip")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            // Two exits, both of which finish with an empty list. Done means the
            // errand is over, so it clears and closes. Clear means start over, so
            // it clears and stays put. Making Done non-destructive was tried and
            // reverted — "Done" on a shopping list reads as "I'm finished", and a
            // Done that leaves everything behind reads as broken.
            // Same idea as the main list: only there when there is something to
            // send, and its absence moves nothing.
            if !store.isEmpty {
                ShareLink(item: ShareText.quickTrip(lines: store.lines)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }

            if !store.isEmpty {
                Button {
                    showClearConfirmation = true
                } label: {
                    Text("Clear")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
            }

            Button {
                if store.isEmpty {
                    isPresented = false
                } else {
                    showDoneConfirmation = true
                }
            } label: {
                Text(store.isEmpty ? "Close" : "Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(DesignSystem.Colors.dillGreen)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .confirmationDialog("Clear the quick trip?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear it", role: .destructive) {
                store.clear()
            }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("Removes all \(store.lines.count) items and starts over. This list is only on this phone, so there is nothing to undo.")
        }
        .confirmationDialog("Finished the trip?", isPresented: $showDoneConfirmation, titleVisibility: .visible) {
            Button("Done — clear the list", role: .destructive) {
                TripStats.shared.recordQuickTrip(
                    itemNames: store.lines.map(\.name),
                    picked: store.lines.filter(\.checked).count
                )
                store.clear()
                isPresented = false
            }
            Button("Keep it open", role: .cancel) { }
        } message: {
            Text("Clears all \(store.lines.count) items and closes. To leave without losing it, swipe down instead.")
        }
    }

    private var subtitle: String {
        if store.isEmpty { return "Only on this phone" }
        return "\(store.remainingCount) left · only on this phone"
    }

    // MARK: - Entry

    private var entryField: some View {
        HStack(spacing: 10) {
            // Was a decorative Image, so tapping it did nothing and the only way
            // to commit was the return key.
            Button(action: commit) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(entry.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? DesignSystem.Colors.textTertiary
                                     : DesignSystem.Colors.dillGreen)
            }
            .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)

            TextField("Add something", text: $entry)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .focused($entryFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                // .onSubmit keeps focus, so a run of items goes in without
                // reaching for the keyboard again between each one.
                .onSubmit(commit)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { entryFocused = false }
                    }
                }

            // Same import sheet the main list uses: speak, camera, photos, paste.
            // A scratch list still deserves dictation — saying six things is the
            // fastest way to fill one.
            Button {
                entryFocused = false
                showImport = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func commit() {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)

        // Submitting an empty field means "I'm done adding", so let go of the
        // keyboard. It used to refocus unconditionally, which made Done reopen
        // the keyboard it had just closed and left no way out.
        guard !trimmed.isEmpty else {
            entryFocused = false
            return
        }

        store.add(trimmed)
        entry = ""
        // Keep focus only after a real add, so a run of items goes in without
        // reaching for the field again.
        entryFocused = true
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(store.lines) { line in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggle(line)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: line.checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(line.checked
                                             ? DesignSystem.Colors.dillGreen
                                             : DesignSystem.Colors.textTertiary)

                        Text(line.name)
                            .font(.system(size: 17))
                            .strikethrough(line.checked, color: DesignSystem.Colors.textTertiary)
                            .foregroundColor(line.checked
                                             ? DesignSystem.Colors.textTertiary
                                             : DesignSystem.Colors.textPrimary)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Safe to full-swipe here: this list is disposable by design
                    // and nothing outside this phone is affected.
                    Button(role: .destructive) {
                        store.remove(line)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .padding(.bottom, 6)
    }

    /// What the big shop currently looks like.
    ///
    /// Read-only in the sense that matters: nothing you tap here changes the
    /// household list. Tapping copies the name onto the quick trip, because
    /// seeing "milk" on the big shop and then having to type it out — or hunt
    /// for it in suggestions — is the whole reason the main list is on screen.
    ///
    /// The copy is a plain string with no link back to the GroceryItem. Ticking
    /// it here does not cross the item off the big shop, and is not meant to.
    ///
    /// Collapsed by default because it is context, not the thing you came here
    /// to do.
    @ViewBuilder
    private var mainListReference: some View {
        let main = viewModel.shoppingList

        if !main.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { mainListExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mainListExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("MAIN LIST")
                            .font(.system(size: 11, weight: .bold))
                            .kerning(0.8)
                        Spacer()
                        Text("\(main.count)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if mainListExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(main) { item in
                                let taken = alreadyTaken(item.name)
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    store.add(item.name)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: taken ? "checkmark" : "plus")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(taken
                                                             ? DesignSystem.Colors.textTertiary.opacity(0.6)
                                                             : DesignSystem.Colors.dillGreen)
                                        Text(item.name)
                                            .font(.system(size: 15))
                                            .foregroundColor(DesignSystem.Colors.textSecondary)
                                        if let quantity = item.quantity, !quantity.isEmpty {
                                            Text(quantity)
                                                .font(.system(size: 13))
                                                .foregroundColor(DesignSystem.Colors.textTertiary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(taken)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .background(DesignSystem.Colors.secondaryBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DesignSystem.Colors.textTertiary.opacity(0.25))
                    .frame(height: 1)
            }
        }
    }

    /// Your own purchase history, browsable here for the same reason it works on
    /// the main list: scrolling past things is how you remember you need them.
    /// Tapping copies the name onto this list — it never touches the household,
    /// and the history itself is untouched. Already-cached, so it works offline.
    ///
    /// Just the suggestions, as everywhere else in the app. It briefly also
    /// carried whatever was on the main list, because those two sets are
    /// mutually exclusive by status and a big-shop item was otherwise impossible
    /// to take on the errand without typing it. The MAIN LIST block above is
    /// tappable now, so that item is one tap away where you actually saw it.
    @ViewBuilder
    private var suggestionsStrip: some View {
        let available = viewModel.suggestions.filter { !alreadyTaken($0.name) }

        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("SUGGESTIONS")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.8)
                    Spacer()
                    Text("\(available.count)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DesignSystem.Colors.neonAmber)
                .padding(.horizontal, 20)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(available) { suggestion in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                store.add(suggestion.name)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(DesignSystem.Colors.neonAmber)
                                    Text(suggestion.name)
                                        .font(.system(size: 15))
                                        .foregroundColor(DesignSystem.Colors.neonAmber.opacity(0.85))
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .frame(maxHeight: 220)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                DesignSystem.Colors.neonAmber.opacity(0.03)
                    .background(DesignSystem.Colors.secondaryBackground)
                    .ignoresSafeArea(edges: .bottom)
            )
            // A rule at the top of each reference block. Without it the three
            // lists ran together and there was no cue that anything sat below the
            // working list once it got long enough to fill the screen.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DesignSystem.Colors.textTertiary.opacity(0.25))
                    .frame(height: 1)
            }
        }
    }

    /// Already on the quick trip. Matched on the name because that is all this
    /// list stores — there is no id to compare against.
    private func alreadyTaken(_ name: String) -> Bool {
        store.lines.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Nothing yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Text("Type what you need. It stays on this phone\nand never touches your shared list.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(DesignSystem.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
