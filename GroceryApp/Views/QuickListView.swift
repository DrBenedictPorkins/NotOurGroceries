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
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(DesignSystem.Colors.dillGreen)

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
        store.add(entry)
        entry = ""
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
