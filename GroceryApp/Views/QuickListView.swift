import SwiftUI

/// "Honey, what do I need?" — a scratch list, on this phone only.
///
/// Everything about it is deliberately narrower than the main list: no store, no
/// aisles, no suggestions, no sync, no history. It is one column of text you can
/// tick. The old Quick Trip failed because it looked like the main list and
/// borrowed its items; this one cannot be confused with anything because there
/// is nothing else on the screen.
struct QuickListView: View {
    @ObservedObject private var store = QuickListStore.shared
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @Binding var isPresented: Bool

    @State private var entry = ""
    @FocusState private var entryFocused: Bool
    @State private var showClearConfirmation = false
    @State private var showImport = false

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                entryField

                if store.isEmpty {
                    empty
                } else {
                    list
                }

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
                Text("Quick list")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            Button {
                if store.isEmpty {
                    isPresented = false
                } else {
                    showClearConfirmation = true
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
        .confirmationDialog("Clear the quick list?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear it", role: .destructive) {
                store.clear()
                isPresented = false
            }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("This list is only on this phone and isn't saved anywhere. Clearing it is permanent.")
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
    }

    /// Your own purchase history, browsable here for the same reason it works on
    /// the main list: scrolling past things is how you remember you need them.
    /// Tapping copies the name onto this list — it never touches the household,
    /// and the history itself is untouched. Already-cached, so it works offline.
    @ViewBuilder
    private var suggestionsStrip: some View {
        let available = viewModel.suggestions.filter { suggestion in
            !store.lines.contains { $0.name.caseInsensitiveCompare(suggestion.name) == .orderedSame }
        }

        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("FROM YOUR USUAL")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.8)
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                    Spacer()
                    Text("\(available.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
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
                                        .foregroundColor(DesignSystem.Colors.dillGreen)
                                    Text(suggestion.name)
                                        .font(.system(size: 15))
                                        .foregroundColor(DesignSystem.Colors.textSecondary)
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
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                DesignSystem.Colors.secondaryBackground
                    .ignoresSafeArea(edges: .bottom)
            )
        }
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
