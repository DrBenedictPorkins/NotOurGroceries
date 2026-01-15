import Foundation

// MARK: - Mapping Source Enum

enum MappingSource: String, Codable {
    case image = "IMAGE"
    case llmGuess = "LLM_GUESS"
}

// MARK: - ProductAisleMapping Model

struct ProductAisleMapping: Identifiable, Codable, Hashable {
    let id: String
    let storeId: String
    var productId: String?
    var normalizedName: String?

    // LLM suggestion (always preserved)
    let aisleId: String
    var confidence: Double?        // 0.0 - 1.0
    var source: MappingSource?     // .image, .llmGuess

    // User override
    var userAisleOverride: String? // Takes precedence when present

    // Audit/Logging
    var reasoning: String?         // "Explicitly listed under Baking"
    var sourceImageKeys: [String]? // S3 keys of contributing images
    var mappedAt: Date?            // When LLM assigned this

    /// Returns the effective aisle ID, preferring user override if present
    var effectiveAisle: String {
        userAisleOverride ?? aisleId
    }

    /// Returns true if confidence is below the threshold (70%)
    var isLowConfidence: Bool {
        guard let confidence = confidence else { return false }
        return confidence < 0.7
    }

    /// Returns true if the user has overridden the LLM suggestion
    var hasUserOverride: Bool {
        userAisleOverride != nil
    }

    /// Returns true if the user override matches the LLM suggestion
    var userConfirmedLLMSuggestion: Bool {
        guard let override = userAisleOverride else { return false }
        return override == aisleId
    }

    init(
        id: String = UUID().uuidString,
        storeId: String,
        productId: String? = nil,
        normalizedName: String? = nil,
        aisleId: String,
        confidence: Double? = nil,
        source: MappingSource? = nil,
        userAisleOverride: String? = nil,
        reasoning: String? = nil,
        sourceImageKeys: [String]? = nil,
        mappedAt: Date? = nil
    ) {
        self.id = id
        self.storeId = storeId
        self.productId = productId
        self.normalizedName = normalizedName
        self.aisleId = aisleId
        self.confidence = confidence
        self.source = source
        self.userAisleOverride = userAisleOverride
        self.reasoning = reasoning
        self.sourceImageKeys = sourceImageKeys
        self.mappedAt = mappedAt
    }
}

// MARK: - Preview Helpers
extension ProductAisleMapping {
    static var preview: ProductAisleMapping {
        ProductAisleMapping(
            id: "mapping1",
            storeId: "store1",
            productId: "product1",
            normalizedName: "whole milk",
            aisleId: "aisle2",
            confidence: 0.95,
            source: .image,
            reasoning: "Explicitly listed on store directory under Dairy",
            mappedAt: Date()
        )
    }

    static var previewList: [ProductAisleMapping] {
        [
            ProductAisleMapping(
                id: "mapping1",
                storeId: "store1",
                productId: "product1",
                normalizedName: "whole milk",
                aisleId: "aisle2",
                confidence: 0.95,
                source: .image,
                reasoning: "Explicitly listed on store directory under Dairy",
                mappedAt: Date()
            ),
            ProductAisleMapping(
                id: "mapping2",
                storeId: "store1",
                productId: nil,
                normalizedName: "bananas",
                aisleId: "aisle1",
                confidence: 0.85,
                source: .llmGuess,
                reasoning: "Bananas are typically in produce section",
                mappedAt: Date()
            ),
            ProductAisleMapping(
                id: "mapping3",
                storeId: "store1",
                productId: "product3",
                normalizedName: "cheerios",
                aisleId: "aisle3",
                confidence: 0.62,
                source: .llmGuess,
                userAisleOverride: "aisle7",
                reasoning: "Cereal products generally near breakfast items",
                mappedAt: Date()
            )
        ]
    }
}
