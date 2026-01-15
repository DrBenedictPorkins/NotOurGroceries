import Foundation

// MARK: - ExtractedProduct Model (from image extraction)

/// Represents a product extracted from a store directory/aisle sign image
struct ExtractedProduct: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var matchedProductId: String?
    var matchedNormalizedName: String?
    var confidence: String  // "high", "medium", "low"

    init(
        id: String = UUID().uuidString,
        name: String,
        matchedProductId: String? = nil,
        matchedNormalizedName: String? = nil,
        confidence: String = "high"
    ) {
        self.id = id
        self.name = name
        self.matchedProductId = matchedProductId
        self.matchedNormalizedName = matchedNormalizedName
        self.confidence = confidence
    }
}

// MARK: - ExtractedAisle Model (from image extraction)

/// Represents an aisle extracted from a store directory image
struct ExtractedAisle: Identifiable, Codable, Hashable {
    let id: String
    var number: String
    var name: String
    var products: [ExtractedProduct]
    var isConfirmed: Bool

    init(
        id: String = UUID().uuidString,
        number: String,
        name: String = "",
        products: [ExtractedProduct] = [],
        isConfirmed: Bool = false
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.products = products
        self.isConfirmed = isConfirmed
    }
}

// MARK: - MappingResult Model (from full product mapping)

/// Represents a single product-to-aisle mapping result from LLM
struct MappingResult: Codable {
    let productId: String?
    let normalizedName: String?
    let aisleId: String
    let confidence: Double
    let reasoning: String
    let source: String

    /// Converts to ProductAisleMapping for saving
    func toProductAisleMapping(storeId: String, sourceImageKeys: [String]? = nil) -> ProductAisleMapping {
        ProductAisleMapping(
            storeId: storeId,
            productId: productId,
            normalizedName: normalizedName,
            aisleId: aisleId,
            confidence: confidence,
            source: MappingSource(rawValue: source),
            reasoning: reasoning,
            sourceImageKeys: sourceImageKeys,
            mappedAt: Date()
        )
    }
}

// MARK: - FullMappingResponse Model

/// Response from the generateFullMappings Lambda
struct FullMappingResponse: Codable {
    let mappings: [MappingResult]
    let stats: MappingStats
}

// MARK: - MappingStats Model

/// Statistics about the mapping operation
struct MappingStats: Codable {
    let total: Int
    let mapped: Int
    let highConfidence: Int  // >= 70%
    let lowConfidence: Int   // < 70%

    var unmapped: Int {
        total - mapped
    }

    var highConfidencePercentage: Double {
        guard mapped > 0 else { return 0 }
        return Double(highConfidence) / Double(mapped) * 100
    }
}

// MARK: - ExtractionResponse Model

/// Response from the extractAisleMappings Lambda
struct ExtractionResponse: Codable {
    let success: Bool
    let aisles: [ExtractedAisle]?
    let totalProducts: Int?
    let error: String?

    init(success: Bool, aisles: [ExtractedAisle]? = nil, totalProducts: Int? = nil, error: String? = nil) {
        self.success = success
        self.aisles = aisles
        self.totalProducts = totalProducts
        self.error = error
    }
}

// MARK: - Preview Helpers

extension ExtractedProduct {
    static var preview: ExtractedProduct {
        ExtractedProduct(name: "Pasta", confidence: "high")
    }

    static func previewProducts(_ names: [String]) -> [ExtractedProduct] {
        names.map { ExtractedProduct(name: $0, confidence: "high") }
    }
}

extension ExtractedAisle {
    static var preview: ExtractedAisle {
        ExtractedAisle(
            id: "extracted1",
            number: "5",
            name: "Pasta & Sauces",
            products: ExtractedProduct.previewProducts(["Pasta", "Spaghetti", "Tomato Sauce", "Alfredo Sauce", "Pesto"])
        )
    }

    static var previewList: [ExtractedAisle] {
        [
            ExtractedAisle(
                id: "extracted1",
                number: "5",
                name: "Pasta & Sauces",
                products: ExtractedProduct.previewProducts(["Pasta", "Spaghetti", "Tomato Sauce", "Alfredo Sauce", "Pesto"])
            ),
            ExtractedAisle(
                id: "extracted2",
                number: "6",
                name: "Baking",
                products: ExtractedProduct.previewProducts(["Flour", "Sugar", "Baking Soda", "Vanilla Extract", "Chocolate Chips"])
            ),
            ExtractedAisle(
                id: "extracted3",
                number: "Dairy",
                name: "Dairy & Eggs",
                products: ExtractedProduct.previewProducts(["Milk", "Cheese", "Yogurt", "Butter", "Eggs"])
            )
        ]
    }
}

extension MappingResult {
    static var preview: MappingResult {
        MappingResult(
            productId: "product1",
            normalizedName: "sugar",
            aisleId: "6",
            confidence: 1.0,
            reasoning: "Explicitly listed on store directory under Baking Supplies",
            source: "IMAGE"
        )
    }

    static var previewList: [MappingResult] {
        [
            MappingResult(
                productId: "product1",
                normalizedName: "sugar",
                aisleId: "6",
                confidence: 1.0,
                reasoning: "Explicitly listed on store directory under Baking Supplies",
                source: "IMAGE"
            ),
            MappingResult(
                productId: "product2",
                normalizedName: "greek yogurt",
                aisleId: "Dairy",
                confidence: 0.95,
                reasoning: "Yogurt products are listed in the Dairy section",
                source: "IMAGE"
            ),
            MappingResult(
                productId: nil,
                normalizedName: "tahini paste",
                aisleId: "6",
                confidence: 0.80,
                reasoning: "International/Middle Eastern items near oils and condiments in Aisle 6",
                source: "LLM_GUESS"
            ),
            MappingResult(
                productId: nil,
                normalizedName: "bread machine yeast",
                aisleId: "6",
                confidence: 0.65,
                reasoning: "Baking supplies including yeast are likely in Aisle 6",
                source: "LLM_GUESS"
            )
        ]
    }
}

extension MappingStats {
    static var preview: MappingStats {
        MappingStats(
            total: 150,
            mapped: 142,
            highConfidence: 98,
            lowConfidence: 44
        )
    }
}

extension FullMappingResponse {
    static var preview: FullMappingResponse {
        FullMappingResponse(
            mappings: MappingResult.previewList,
            stats: MappingStats.preview
        )
    }
}
