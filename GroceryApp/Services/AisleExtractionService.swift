import Foundation
import SwiftUI
import Amplify
import AWSPluginsCore
import os.log

private let logger = Logger(subsystem: "com.byteclub.grocery.app", category: "AisleExtraction")

// MARK: - AisleExtractionService

@MainActor
class AisleExtractionService: ObservableObject {
    static let shared = AisleExtractionService()

    // MARK: - User Override

    /// Update a single mapping with a user override
    func updateUserOverride(mappingId: String, userAisleOverride: String?) async throws {
        let document = """
        mutation UpdateProductAisleMapping($input: UpdateProductAisleMappingInput!) {
            updateProductAisleMapping(input: $input) {
                id
                userAisleOverride
            }
        }
        """

        var input: [String: Any] = ["id": mappingId]
        if let override = userAisleOverride {
            input["userAisleOverride"] = override
        } else {
            input["userAisleOverride"] = NSNull()
        }

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            _ = try await API.mutate(request)
        } catch let failure as ServiceFailure {
            logger.error("Failed to update user override: \(failure.errorDescription ?? "")")
            throw failure
        }

        logger.info("Updated user override for mapping \(mappingId)")
    }

    // MARK: - Private: Database Operations

    /// Fetch existing mappings for a store
    private func fetchExistingMappings(storeId: String) async throws -> [ProductAisleMapping] {
        var allMappings: [ProductAisleMapping] = []
        var nextToken: String? = nil

        repeat {
            let (mappings, token) = try await fetchMappingBatch(storeId: storeId, nextToken: nextToken)
            allMappings.append(contentsOf: mappings)
            nextToken = token
        } while nextToken != nil

        return allMappings
    }

    /// Fetch a batch of mappings
    private func fetchMappingBatch(storeId: String, nextToken: String?) async throws -> ([ProductAisleMapping], String?) {
        var variables: [String: Any] = [
            "storeId": storeId,
            "limit": 500
        ]
        if let token = nextToken {
            variables["nextToken"] = token
        }

        let document = """
        query ListProductAisleMappings($storeId: ID!, $limit: Int, $nextToken: String) {
            listProductAisleMappingsByStore(storeId: $storeId, limit: $limit, nextToken: $nextToken) {
                items {
                    id
                    storeId
                    productId
                    normalizedName
                    aisleId
                    confidence
                    source
                    userAisleOverride
                    reasoning
                    sourceImageKeys
                    mappedAt
                }
                nextToken
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let json = try await API.query(request)

        guard case .object(let root) = json,
              case .object(let listResult) = root["listProductAisleMappingsByStore"],
              case .array(let items) = listResult["items"] else {
            return ([], nil)
        }

        let mappings = items.compactMap { parseMapping($0) }

        var token: String? = nil
        if case .string(let t) = listResult["nextToken"] {
            token = t
        }

        return (mappings, token)
    }

    /// Parse a single mapping from JSON
    private func parseMapping(_ json: JSONValue) -> ProductAisleMapping? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let storeId) = obj["storeId"],
              case .string(let aisleId) = obj["aisleId"] else {
            return nil
        }

        var productId: String? = nil
        if case .string(let pid) = obj["productId"] {
            productId = pid
        }

        var normalizedName: String? = nil
        if case .string(let name) = obj["normalizedName"] {
            normalizedName = name
        }

        var confidence: Double? = nil
        if case .number(let c) = obj["confidence"] {
            confidence = c
        }

        var source: MappingSource? = nil
        if case .string(let s) = obj["source"] {
            source = MappingSource(rawValue: s)
        }

        var userAisleOverride: String? = nil
        if case .string(let override) = obj["userAisleOverride"] {
            userAisleOverride = override
        }

        var reasoning: String? = nil
        if case .string(let r) = obj["reasoning"] {
            reasoning = r
        }

        var sourceImageKeys: [String]? = nil
        if case .array(let keys) = obj["sourceImageKeys"] {
            sourceImageKeys = keys.compactMap { key in
                if case .string(let k) = key { return k }
                return nil
            }
        }

        var mappedAt: Date? = nil
        if case .string(let dateStr) = obj["mappedAt"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            mappedAt = formatter.date(from: dateStr)
        }

        return ProductAisleMapping(
            id: id,
            storeId: storeId,
            productId: productId,
            normalizedName: normalizedName,
            aisleId: aisleId,
            confidence: confidence,
            source: source,
            userAisleOverride: userAisleOverride,
            reasoning: reasoning,
            sourceImageKeys: sourceImageKeys,
            mappedAt: mappedAt
        )
    }

    /// Create a new mapping
    private func createMapping(
        productId: String,
        storeId: String,
        aisleId: String,
        confidence: Double,
        reasoning: String
    ) async throws {
        let mappingId = UUID().uuidString
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let document = """
        mutation CreateProductAisleMapping($input: CreateProductAisleMappingInput!) {
            createProductAisleMapping(input: $input) {
                id
            }
        }
        """

        let input: [String: Any] = [
            "id": mappingId,
            "storeId": storeId,
            "productId": productId,
            "aisleId": aisleId,
            "confidence": confidence,
            "source": MappingSource.llmGuess.rawValue,
            "reasoning": reasoning,
            "mappedAt": iso8601Formatter.string(from: Date())
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        _ = try await API.mutate(request)
    }

    /// Update an existing mapping
    private func updateMapping(
        id: String,
        aisleId: String,
        confidence: Double,
        reasoning: String
    ) async throws {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let document = """
        mutation UpdateProductAisleMapping($input: UpdateProductAisleMappingInput!) {
            updateProductAisleMapping(input: $input) {
                id
            }
        }
        """

        let input: [String: Any] = [
            "id": id,
            "aisleId": aisleId,
            "confidence": confidence,
            "source": MappingSource.llmGuess.rawValue,
            "reasoning": reasoning,
            "mappedAt": iso8601Formatter.string(from: Date())
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        _ = try await API.mutate(request)
    }

    // MARK: - Single Product Aisle Inference

    /// Result from AI aisle inference for a single product
    struct AisleInferenceResult {
        var suggestedAisle: String
        let confidence: Double
        let reasoning: String
    }


    // MARK: - Batch Inference

    /// Input item for batch inference
    struct BatchInferenceInput {
        let id: String           // GroceryItem id for mapping results back
        let productName: String
        let normalizedName: String
        let productId: String?
    }

    /// Batch infer aisles for multiple products (single LLM call)
    /// - Parameters:
    ///   - storeId: Store to infer aisles for
    ///   - items: Array of items to infer
    /// - Returns: Dictionary mapping item ID to inference result
    func inferProductAisleBatch(
        storeId: String,
        items: [BatchInferenceInput]
    ) async throws -> [String: AisleInferenceResult] {
        logger.info("[INFER-BATCH] Requesting batch aisle inference for \(items.count) items in store \(storeId)")

        // Build products array for GraphQL
        var productsArray: [[String: Any]] = []
        for item in items {
            var product: [String: Any] = [
                "productName": item.productName,
                "normalizedName": item.normalizedName
            ]
            if let productId = item.productId {
                product["productId"] = productId
            }
            productsArray.append(product)
        }

        // Encode products to JSON string for AWSJSON
        let productsData = try JSONSerialization.data(withJSONObject: productsArray)
        let productsJson = String(data: productsData, encoding: .utf8) ?? "[]"

        let document = """
        mutation InferProductAisleBatch($storeId: ID!, $products: AWSJSON!) {
            inferProductAisleBatch(storeId: $storeId, products: $products)
        }
        """

        let variables: [String: Any] = [
            "storeId": storeId,
            "products": productsJson
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let json: JSONValue
        do {
            json = try await API.mutate(request)
        } catch let failure as ServiceFailure {
            logger.error("[INFER-BATCH] GraphQL error: \(failure.errorDescription ?? "")")
            throw failure
        }

        // Parse the response - it's a JSON string that we need to decode
        guard case .object(let root) = json,
              case .string(let resultString) = root["inferProductAisleBatch"] else {
            throw AisleExtractionError.parseFailed("Invalid response format")
        }

        // Parse the JSON string response
        guard let resultData = resultString.data(using: .utf8) else {
            throw AisleExtractionError.parseFailed("Could not parse response data")
        }

        struct BatchResponse: Decodable {
            let success: Bool
            let error: String?
            let results: [BatchResult]?
        }

        struct BatchResult: Decodable {
            let productName: String
            let normalizedName: String?
            let productId: String?
            let suggestedAisle: String
            let confidence: Double
            let reasoning: String
        }

        let batchResponse = try JSONDecoder().decode(BatchResponse.self, from: resultData)

        guard batchResponse.success, let results = batchResponse.results else {
            let errorMsg = batchResponse.error ?? "Batch inference failed"
            // Check if this is an API key configuration error
            if AisleExtractionError.isApiKeyError(errorMsg) {
                throw AisleExtractionError.apiKeyNotConfigured
            }
            throw AisleExtractionError.processingFailed(errorMsg)
        }

        // Map results back to item IDs
        var resultDict: [String: AisleInferenceResult] = [:]
        for result in results {
            // Find matching input item by productName
            if let item = items.first(where: { $0.productName == result.productName }) {
                resultDict[item.id] = AisleInferenceResult(
                    suggestedAisle: result.suggestedAisle,
                    confidence: result.confidence,
                    reasoning: result.reasoning
                )
            }
        }

        logger.info("[INFER-BATCH] Got \(resultDict.count) results")
        return resultDict
    }

    /// Save batch inference results to database
    /// Reuses existing createMappingFromInference for each item
    /// What actually happened to a batch, in three separate numbers.
    ///
    /// It used to return one count, and the caller subtracted it from the input
    /// count and called the difference "didn't save". Two of the three ways an
    /// item can end up unplaced are not failures at all — the model returned
    /// nothing for it, or it invented an aisle the store does not have — so a
    /// batch where the model simply could not place two items reported "Placed 1
    /// of 3. The rest didn't save", on a working connection, having saved
    /// everything it was given. Observed 2026-09-06.
    struct BatchSaveOutcome {
        /// Written to the server.
        var placed = 0
        /// The model had no aisle for these, or named one the store does not
        /// have. Nothing was attempted and nothing was charged.
        var unplaced = 0
        /// Attempted and threw. The only number that means "try again".
        var failed = 0
        /// Why the first failure failed, so the sheet can say something true
        /// instead of asking a global network probe what it thinks. Nil when
        /// nothing failed.
        var firstFailure: ServiceFailure?
    }

    @discardableResult
    func saveBatchInferenceResults(
        items: [BatchInferenceInput],
        results: [String: AisleInferenceResult],
        storeId: String
    ) async throws -> BatchSaveOutcome {
        var outcome = BatchSaveOutcome()

        // Only persist an aisle the store actually declares. Inference used to be
        // able to invent one ("Not mapped (likely Baking/Dry Goods aisle)") and it
        // was saved and then rendered as a section header.
        let store = await StoreService.shared.householdStores.first(where: { $0.id == storeId })
        // Numbers count too. A mapping legitimately stores an aisle's number,
        // and leaving them out meant a correction to a numbered aisle — the most
        // common kind — was discarded here as an invented one.
        let validAisleIds: Set<String> = Set(
            (store?.aisleLayout.map { $0.id } ?? [])
                + (store?.aisleLayout.map { $0.name } ?? [])
                + (store?.aisleLayout.map { $0.number } ?? [])
        ).subtracting([""])

        for item in items {
            guard let result = results[item.id] else {
                outcome.unplaced += 1
                continue
            }
            guard validAisleIds.isEmpty || validAisleIds.contains(result.suggestedAisle) else {
                print("[INFER] Discarding invented aisle \(result.suggestedAisle) for \(item.productName)")
                outcome.unplaced += 1
                continue
            }

            do {
                try await createMappingFromInference(
                    productName: item.productName,
                    normalizedName: item.normalizedName,
                    productId: item.productId,
                    storeId: storeId,
                    inference: result
                )
                outcome.placed += 1
            } catch {
                let failure = ServiceFailure.from(error)
                logger.error("[INFER-BATCH] Failed to save mapping for '\(item.productName)': \(failure)")
                outcome.failed += 1
                if outcome.firstFailure == nil { outcome.firstFailure = failure }
            }
        }

        logger.info("[INFER-BATCH] Placed \(outcome.placed), unplaced \(outcome.unplaced), failed \(outcome.failed) of \(items.count)")
        return outcome
    }


    /// Create a new mapping from an accepted inference result
    func createMappingFromInference(
        productName: String,
        normalizedName: String,
        productId: String?,
        storeId: String,
        inference: AisleInferenceResult
    ) async throws {
        let mappingId = "\(storeId)-\(productId ?? normalizedName)"
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Checked against the caller's group claim inside the resolver, and
        // written onto the row so it can be read back under the same rule.
        guard let householdId = AmplifyService.shared.currentHouseholdId, !householdId.isEmpty else {
            throw NSError(domain: "AisleExtractionService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No household selected"])
        }

        let document = """
        mutation UpsertProductAisleMapping(
            $id: String!, $householdId: ID!, $storeId: ID!, $aisleId: String!,
            $normalizedName: String, $productId: ID,
            $confidence: Float, $source: String, $reasoning: String, $mappedAt: AWSDateTime
        ) {
            upsertProductAisleMapping(
                id: $id, householdId: $householdId, storeId: $storeId, aisleId: $aisleId,
                normalizedName: $normalizedName, productId: $productId,
                confidence: $confidence, source: $source, reasoning: $reasoning, mappedAt: $mappedAt
            ) {
                id
                aisleId
            }
        }
        """

        var variables: [String: Any] = [
            "id": mappingId,
            "householdId": householdId,
            "storeId": storeId,
            "normalizedName": normalizedName,
            "aisleId": inference.suggestedAisle,
            "confidence": inference.confidence,
            "source": MappingSource.llmGuess.rawValue,
            "reasoning": inference.reasoning,
            "mappedAt": iso8601Formatter.string(from: Date())
        ]

        if let productId = productId {
            variables["productId"] = productId
        }

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        _ = try await API.mutate(request)

        logger.info("[INFER] Upserted mapping for '\(productName)' -> aisle \(inference.suggestedAisle)")
    }
}

// MARK: - Errors

enum AisleExtractionError: LocalizedError {
    case uploadFailed(String)
    case processingFailed(String)
    case parseFailed(String)
    case mergeFailed(String)
    case apiKeyNotConfigured

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        case .parseFailed(let message):
            return "Parse failed: \(message)"
        case .mergeFailed(let message):
            return "Merge failed: \(message)"
        case .apiKeyNotConfigured:
            return "AI features are not available. The API key has not been configured for this environment."
        }
    }

    /// Check if an error message indicates an API key configuration issue
    static func isApiKeyError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("api key") ||
               lowercased.contains("api_key") ||
               lowercased.contains("apikey") ||
               lowercased.contains("authentication") ||
               lowercased.contains("401") ||
               lowercased.contains("unauthorized") ||
               lowercased.contains("invalid key") ||
               lowercased.contains("missing key")
    }
}
