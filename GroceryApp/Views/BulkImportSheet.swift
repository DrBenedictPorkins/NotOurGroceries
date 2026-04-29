import SwiftUI
import Amplify
import AWSPluginsCore

// MARK: - Data Model

struct ParsedIngredient: Identifiable {
    let id = UUID()
    var name: String
    var quantity: String?
    var isSelected: Bool = true
}

// MARK: - Phase

private enum ImportPhase {
    case input
    case parsing
    case review([ParsedIngredient])
    case adding(done: Int, total: Int)
}

// MARK: - BulkImportSheet

struct BulkImportSheet: View {
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @Binding var isPresented: Bool

    @State private var rawText = ""
    @State private var phase: ImportPhase = .input
    @State private var ingredients: [ParsedIngredient] = []
    @State private var errorMessage: String?
    @FocusState private var editorFocused: Bool

    private var selectedCount: Int {
        ingredients.filter(\.isSelected).count
    }

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

            VStack(spacing: 0) {
                headerBar
                    .padding(.top, 20)

                switch phase {
                case .input:
                    inputView
                case .parsing:
                    parsingView
                case .review:
                    reviewView
                case .adding(let done, let total):
                    addingView(done: done, total: total)
                }
            }
        }
        .onAppear { editorFocused = true }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)

            Spacer()

            Text("Import Items")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            Spacer()

            // Invisible balance element
            Text("Cancel")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.clear)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Input Phase

    private var inputView: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste a recipe, shopping notes, or any list of items")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 20)

                ZStack(alignment: .topLeading) {
                    if rawText.isEmpty {
                        Text("e.g. 2 cups flour, 3 eggs, 1 stick butter\nor a full recipe ingredient list...")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $rawText)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .frame(minHeight: 180)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            DesignSystem.Colors.neonCyan.opacity(editorFocused ? 0.5 : 0.2),
                                            DesignSystem.Colors.neonPurple.opacity(editorFocused ? 0.3 : 0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: editorFocused ? 1.5 : 1
                                )
                        )
                )
                .padding(.horizontal, 20)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonPink)
                    .padding(.horizontal, 20)
            }

            Spacer()

            parseButton
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
        }
        .padding(.top, 4)
    }

    private var parseButton: some View {
        Button(action: startParsing) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                Text("Parse Items")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.3) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.white.opacity(0.05)
                        : DesignSystem.Colors.neonCyan.opacity(0.2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.white.opacity(0.1)
                                : DesignSystem.Colors.neonCyan.opacity(0.6),
                                lineWidth: 1.5
                            )
                    )
            )
        }
        .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .buttonStyle(.plain)
    }

    // MARK: - Parsing Phase

    private var parsingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(DesignSystem.Colors.neonCyan)

                Text("Parsing ingredients...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
    }

    // MARK: - Review Phase

    private var reviewView: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack {
                Text("\(ingredients.count) item\(ingredients.count == 1 ? "" : "s") found")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonCyan)

                Spacer()

                Button(action: toggleAll) {
                    Text(selectedCount == ingredients.count ? "Deselect All" : "Select All")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Items list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($ingredients) { $item in
                        IngredientReviewRow(item: $item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100) // space for button
            }

            // Add button
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.1))
                addButton
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
            }
            .background(DesignSystem.Colors.background)
        }
    }

    private var addButton: some View {
        Button(action: addSelectedItems) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(selectedCount == 0 ? "No Items Selected" : "Add \(selectedCount) Item\(selectedCount == 1 ? "" : "s")")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(selectedCount == 0 ? .white.opacity(0.3) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        selectedCount == 0
                        ? Color.white.opacity(0.05)
                        : DesignSystem.Colors.neonCyan.opacity(0.2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                selectedCount == 0
                                ? Color.white.opacity(0.1)
                                : DesignSystem.Colors.neonCyan.opacity(0.6),
                                lineWidth: 1.5
                            )
                    )
            )
        }
        .disabled(selectedCount == 0)
        .buttonStyle(.plain)
    }

    // MARK: - Adding Phase

    private func addingView(done: Int, total: Int) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(DesignSystem.Colors.neonCyan)
                    .padding(.horizontal, 40)

                Text("Adding \(done) of \(total) items...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func startParsing() {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        errorMessage = nil
        editorFocused = false
        phase = .parsing

        Task {
            do {
                let items = try await callParseIngredients(text: text)
                await MainActor.run {
                    if items.isEmpty {
                        errorMessage = "No grocery items found. Try rephrasing the text."
                        phase = .input
                    } else {
                        ingredients = items
                        phase = .review(items)
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to parse items. Please try again."
                    phase = .input
                }
            }
        }
    }

    private func toggleAll() {
        let allSelected = selectedCount == ingredients.count
        for i in ingredients.indices {
            ingredients[i].isSelected = !allSelected
        }
    }

    private func addSelectedItems() {
        let selected = ingredients.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        let total = selected.count
        phase = .adding(done: 0, total: total)

        Task {
            for (i, item) in selected.enumerated() {
                await viewModel.addItem(name: item.name, quantity: item.quantity)
                await MainActor.run {
                    phase = .adding(done: i + 1, total: total)
                }
            }
            await MainActor.run {
                isPresented = false
            }
        }
    }

    // MARK: - GraphQL

    private func callParseIngredients(text: String) async throws -> [ParsedIngredient] {
        let document = """
        mutation ParseIngredients($rawText: String!) {
            parseIngredients(rawText: $rawText)
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["rawText": text],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            guard case .object(let root) = json,
                  case .string(let resultString) = root["parseIngredients"],
                  let data = resultString.data(using: .utf8) else {
                return []
            }

            struct RawItem: Decodable {
                let name: String
                let quantity: String?
            }

            let rawItems = try JSONDecoder().decode([RawItem].self, from: data)
            return rawItems.map { ParsedIngredient(name: $0.name, quantity: $0.quantity) }

        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Ingredient Review Row

private struct IngredientReviewRow: View {
    @Binding var item: ParsedIngredient

    var body: some View {
        Button(action: { item.isSelected.toggle() }) {
            HStack(spacing: 14) {
                // Checkbox
                ZStack {
                    Circle()
                        .fill(item.isSelected ? DesignSystem.Colors.neonCyan.opacity(0.2) : Color.white.opacity(0.05))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(
                                    item.isSelected ? DesignSystem.Colors.neonCyan : Color.white.opacity(0.2),
                                    lineWidth: 1.5
                                )
                        )

                    if item.isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(DesignSystem.Colors.neonCyan)
                    }
                }

                // Name
                Text(item.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(item.isSelected ? .white : DesignSystem.Colors.textSecondary)
                    .strikethrough(!item.isSelected, color: DesignSystem.Colors.textTertiary)

                Spacer()

                // Quantity badge
                if let qty = item.quantity, !qty.isEmpty {
                    Text(qty)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.07))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(item.isSelected ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                item.isSelected
                                ? DesignSystem.Colors.neonCyan.opacity(0.2)
                                : Color.white.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: item.isSelected)
    }
}
