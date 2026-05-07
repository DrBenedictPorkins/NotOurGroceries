import SwiftUI
import Amplify
import AWSPluginsCore
import PhotosUI

// MARK: - Data Model

struct ParsedIngredient: Identifiable {
    let id = UUID()
    var name: String
    var quantity: String?
    var notes: String?
    var productId: String?
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
    @State private var selectedImage: UIImage? = nil
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
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
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $selectedImage)
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { selectedImage = img }
                }
                await MainActor.run { photoPickerItem = nil }
            }
        }
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

    private var hasInput: Bool {
        selectedImage != nil || !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputView: some View {
        VStack(spacing: 20) {
            if let image = selectedImage {
                imagePreviewSection(image: image)
            } else {
                textInputSection
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

    private var textInputSection: some View {
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

            // Image source buttons
            HStack(spacing: 12) {
                Spacer()
                imageSourceButton(icon: "camera.fill", label: "Camera") {
                    editorFocused = false
                    showCamera = true
                }
                imageSourceButton(icon: "photo.fill", label: "Photos") {
                    editorFocused = false
                    showPhotoPicker = true
                }
                imageSourceButton(icon: "doc.on.clipboard", label: "Paste") {
                    if let img = UIPasteboard.general.image {
                        editorFocused = false
                        selectedImage = img
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
    }

    private func imagePreviewSection(image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image ready — tap Scan to extract items")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 20)

            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                Button(action: { selectedImage = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .padding(.trailing, 28)
                .padding(.top, 8)
            }
        }
    }

    private func imageSourceButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DesignSystem.Colors.textSecondary)
            .frame(width: 68, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var parseButton: some View {
        Button(action: startParsing) {
            HStack(spacing: 10) {
                Image(systemName: selectedImage != nil ? "eye" : "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                Text(selectedImage != nil ? "Scan Image" : "Parse Items")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(hasInput ? .white : .white.opacity(0.3))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(hasInput ? DesignSystem.Colors.neonCyan.opacity(0.2) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                hasInput ? DesignSystem.Colors.neonCyan.opacity(0.6) : Color.white.opacity(0.1),
                                lineWidth: 1.5
                            )
                    )
            )
        }
        .disabled(!hasInput)
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
        errorMessage = nil
        editorFocused = false
        phase = .parsing

        Task {
            do {
                var items: [ParsedIngredient]
                if let image = selectedImage {
                    items = try await callParseIngredients(image: image)
                } else {
                    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        await MainActor.run { phase = .input }
                        return
                    }
                    items = try await callParseIngredients(text: text)
                }

                for i in items.indices {
                    if let match = ProductCache.shared.findMatchingProduct(for: items[i].name) {
                        items[i].productId = match.id
                    }
                }
                await MainActor.run {
                    if items.isEmpty {
                        errorMessage = "No grocery items found. Try a different image or rephrase the text."
                        phase = .input
                    } else {
                        ingredients = items
                        phase = .review(items)
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to parse. Please try again."
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
                await viewModel.addItem(name: item.name, quantity: item.quantity, notes: item.notes, productId: item.productId)
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
        mutation ParseIngredients($rawText: String!, $knownTerms: [String]) {
            parseIngredients(rawText: $rawText, knownTerms: $knownTerms)
        }
        """

        let knownTerms = ProductCache.shared.products.map { $0.normalizedName }
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["rawText": text, "knownTerms": knownTerms],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            return extractIngredients(from: json)
        case .failure(let error):
            if case GraphQLResponseError<JSONValue>.partial(let json, _) = error {
                return extractIngredients(from: json)
            }
            if case GraphQLResponseError<JSONValue>.transformationError(let raw, _) = error {
                return try extractIngredientsFromRaw(raw)
            }
            throw error
        }
    }

    private func callParseIngredients(image: UIImage) async throws -> [ParsedIngredient] {
        guard let jpegData = resizeImage(image) else {
            throw NSError(domain: "BulkImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
        }
        let base64 = jpegData.base64EncodedString()

        // rawText is required in schema until Amplify Console deploys the schema update —
        // passing empty string; Lambda ignores it when imageData is present.
        let document = """
        mutation ParseIngredients($rawText: String!, $knownTerms: [String], $imageData: String) {
            parseIngredients(rawText: $rawText, knownTerms: $knownTerms, imageData: $imageData)
        }
        """

        let knownTerms = ProductCache.shared.products.map { $0.normalizedName }
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["rawText": "", "knownTerms": knownTerms, "imageData": base64],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            return extractIngredients(from: json)
        case .failure(let error):
            if case GraphQLResponseError<JSONValue>.partial(let json, _) = error {
                return extractIngredients(from: json)
            }
            if case GraphQLResponseError<JSONValue>.transformationError(let raw, _) = error {
                return try extractIngredientsFromRaw(raw)
            }
            throw error
        }
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat = 1568) -> Data? {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    private func extractIngredients(from json: JSONValue) -> [ParsedIngredient] {
        guard case .object(let root) = json else { return [] }
        switch root["parseIngredients"] {
        case .array(let array):
            return array.compactMap { element -> ParsedIngredient? in
                guard case .object(let obj) = element,
                      case .string(let name) = obj["name"] else { return nil }
                let qty: String? = { if case .string(let q) = obj["quantity"] { return q }; return nil }()
                let notes: String? = { if case .string(let q) = obj["qualifier"] { return q }; return nil }()
                return ParsedIngredient(name: name, quantity: qty, notes: notes)
            }
        case .string(let s):
            guard let data = s.data(using: .utf8),
                  let items = try? JSONDecoder().decode([_RawItem].self, from: data) else { return [] }
            return items.map { ParsedIngredient(name: $0.name, quantity: $0.quantity, notes: $0.qualifier) }
        default:
            return []
        }
    }

    private func extractIngredientsFromRaw(_ raw: String) throws -> [ParsedIngredient] {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = obj["data"] as? [String: Any] else { return [] }

        if let str = dataObj["parseIngredients"] as? String {
            guard let itemData = str.data(using: .utf8) else { return [] }
            let items = try JSONDecoder().decode([_RawItem].self, from: itemData)
            return items.map { ParsedIngredient(name: $0.name, quantity: $0.quantity, notes: $0.qualifier) }
        } else if let arr = dataObj["parseIngredients"] as? [[String: Any]] {
            return arr.compactMap { obj -> ParsedIngredient? in
                guard let name = obj["name"] as? String else { return nil }
                return ParsedIngredient(name: name, quantity: obj["quantity"] as? String, notes: obj["qualifier"] as? String)
            }
        }
        return []
    }
}

private struct _RawItem: Decodable {
    let name: String
    let quantity: String?
    let qualifier: String?
}

// MARK: - Ingredient Review Row

private struct IngredientReviewRow: View {
    @Binding var item: ParsedIngredient

    private var nameLabel: Text {
        if let notes = item.notes, !notes.isEmpty {
            return (Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.isSelected ? .white : DesignSystem.Colors.textSecondary)
            + Text(" · ")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            + Text(notes)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary))
            .strikethrough(!item.isSelected, color: DesignSystem.Colors.textTertiary)
        } else {
            return Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.isSelected ? .white : DesignSystem.Colors.textSecondary)
                .strikethrough(!item.isSelected, color: DesignSystem.Colors.textTertiary)
        }
    }

    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 14) {
            // Checkbox — only this toggles selection
            Button(action: { item.isSelected.toggle() }) {
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
            }
            .buttonStyle(.plain)

            nameLabel

            if item.productId != nil {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.neonCyan.opacity(item.isSelected ? 0.7 : 0.3))
            } else {
                Text("new")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonPurple.opacity(item.isSelected ? 0.8 : 0.3))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignSystem.Colors.neonPurple.opacity(item.isSelected ? 0.12 : 0.05))
                    )
            }

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

            // Detail button
            Button(action: { showDetail = true }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
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
        .animation(.easeInOut(duration: 0.15), value: item.isSelected)
        .sheet(isPresented: $showDetail) {
            IngredientDetailSheet(item: $item)
        }
    }
}

// MARK: - Ingredient Detail Sheet

private struct IngredientDetailSheet: View {
    @Binding var item: ParsedIngredient
    @Environment(\.dismiss) var dismiss

    @State private var editName: String
    @State private var editQuantity: String
    @State private var editNotes: String

    init(item: Binding<ParsedIngredient>) {
        self._item = item
        self._editName = State(initialValue: item.wrappedValue.name)
        self._editQuantity = State(initialValue: item.wrappedValue.quantity ?? "")
        self._editNotes = State(initialValue: item.wrappedValue.notes ?? "")
    }

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

                ScrollView {
                    VStack(spacing: 0) {
                        // Item name header
                        Text(editName.isEmpty ? item.name : editName)
                            .font(DesignSystem.Typography.title2)
                            .foregroundColor(DesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DesignSystem.Spacing.lg)
                            .padding(.top, DesignSystem.Spacing.md)
                            .padding(.bottom, DesignSystem.Spacing.lg)

                        Divider().background(DesignSystem.Colors.glassBorder)

                        VStack(spacing: DesignSystem.Spacing.lg) {
                            fieldSection(label: "Name") {
                                TextField("Item name", text: $editName)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .padding(DesignSystem.Spacing.md)
                                    .background(fieldBackground)
                            }

                            fieldSection(label: "Quantity") {
                                TextField("e.g. 2, 1 lb, 3 cups", text: $editQuantity)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .padding(DesignSystem.Spacing.md)
                                    .background(fieldBackground)
                            }

                            fieldSection(label: "Notes") {
                                TextField("Add notes (e.g., Kosher, Large size, Brand: Heinz)", text: $editNotes, axis: .vertical)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundColor(DesignSystem.Colors.textPrimary)
                                    .lineLimit(3...6)
                                    .padding(DesignSystem.Spacing.md)
                                    .background(fieldBackground)
                            }
                        }
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.top, DesignSystem.Spacing.lg)
                        .padding(.bottom, DesignSystem.Spacing.xxl)
                    }
                }
            }
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty { item.name = trimmedName }
                        let trimmedQty = editQuantity.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.quantity = trimmedQty.isEmpty ? nil : trimmedQty
                        let trimmedNotes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .font(DesignSystem.Typography.headline)
                }
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
            .fill(DesignSystem.Colors.glassBackground)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
    }

    private func fieldSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(label)
                .font(DesignSystem.Typography.footnote)
                .foregroundColor(DesignSystem.Colors.textSecondary)
            content()
        }
    }
}

// MARK: - Camera Picker

private struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
