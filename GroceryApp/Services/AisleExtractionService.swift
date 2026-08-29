import Foundation
import SwiftUI
import Amplify
import AWSPluginsCore
import os.log

private let logger = Logger(subsystem: "com.byteclub.grocery.app", category: "AisleExtraction")

// MARK: - Job Model

/// Represents an aisle extraction job processed by Lambda
struct AisleExtractionJob: Codable {
    let id: String
    let storeId: String
    let status: String  // PENDING, EXTRACTING, MATCHING, APPLYING, COMPLETE, FAILED
    let phase: Int?
    let phaseLabel: String?
    let detail: String?
    let retryCount: Int?
    let lastError: String?
    let entriesExtracted: Int?
    let mappingsCreated: Int?
    let highConfidence: Int?
    let lowConfidence: Int?
}

// MARK: - Legacy Models (kept for compatibility)

/// Raw aisle entry extracted from store directory image
struct AisleEntry: Codable {
    let productName: String
    let aisle: String
}

/// Product mapping result with confidence
struct LLMMappingResult: Codable {
    let productId: String
    let aisleId: String
    let confidence: Double
    let reasoning: String
}

// MARK: - Phase 3: Merge Stats

/// Statistics from applying mappings with smart merge
struct MergeStats {
    let updated: Int
    let skippedUserOverride: Int
    let skippedLowerConfidence: Int

    var total: Int {
        updated + skippedUserOverride + skippedLowerConfidence
    }
}

// MARK: - AisleExtractionService

@MainActor
class AisleExtractionService: ObservableObject {
    static let shared = AisleExtractionService()

    // MARK: - Published State

    @Published var isProcessing = false
    @Published var processingStatus: String = ""
    @Published var currentPhase: Int = 0  // 0=idle, 1=OCR, 2=Match, 3=Apply
    @Published var lastError: String?
    @Published var currentJob: AisleExtractionJob?
    @Published var secondsUntilNextPoll: Int = 0

    // MARK: - Private Properties

    private let storagePrefix = "store-images"
    private let pollIntervalSeconds = 2
    private var pollingTask: Task<AisleExtractionJob, Error>?

    // MARK: - Persistence Keys

    private let activeJobsKey = "AisleExtractionActiveJobs"  // [storeId: jobId]

    private init() {}

    // MARK: - Active Job Persistence

    /// Get active job ID for a store (if any)
    func activeJobId(for storeId: String) -> String? {
        let jobs = UserDefaults.standard.dictionary(forKey: activeJobsKey) as? [String: String] ?? [:]
        return jobs[storeId]
    }

    /// Save active job ID for a store
    private func saveActiveJob(storeId: String, jobId: String) {
        var jobs = UserDefaults.standard.dictionary(forKey: activeJobsKey) as? [String: String] ?? [:]
        jobs[storeId] = jobId
        UserDefaults.standard.set(jobs, forKey: activeJobsKey)
    }

    /// Clear active job for a store
    private func clearActiveJob(storeId: String) {
        var jobs = UserDefaults.standard.dictionary(forKey: activeJobsKey) as? [String: String] ?? [:]
        jobs.removeValue(forKey: storeId)
        UserDefaults.standard.set(jobs, forKey: activeJobsKey)
    }

    /// Check if there's an active job for a store and resume polling if so
    /// Returns the completed job if found and finished, nil if no active job
    @discardableResult
    func resumeActiveJob(for storeId: String) async throws -> AisleExtractionJob? {
        guard let jobId = activeJobId(for: storeId) else {
            return nil
        }

        logger.info("[JOB] Found active job \(jobId) for store \(storeId), checking status...")

        // Fetch current job status
        let job = try await fetchJob(jobId: jobId)

        // If already complete or failed, clear it and return
        if job.status == "COMPLETE" {
            clearActiveJob(storeId: storeId)
            return job
        } else if job.status == "FAILED" {
            clearActiveJob(storeId: storeId)
            let errorMsg = job.lastError ?? "Unknown error"
            if AisleExtractionError.isApiKeyError(errorMsg) {
                throw AisleExtractionError.apiKeyNotConfigured
            }
            throw AisleExtractionError.processingFailed(errorMsg)
        }

        // Job is still in progress, resume polling
        logger.info("[JOB] Resuming polling for job \(jobId)")
        isProcessing = true
        currentJob = job
        processingStatus = job.detail ?? job.phaseLabel ?? "Processing..."
        currentPhase = job.phase ?? 0

        // Start polling in background
        pollingTask = Task {
            try await pollJobUntilComplete(jobId: jobId, storeId: storeId)
        }

        return try await pollingTask!.value
    }

    /// Check if currently processing a job for a specific store
    func isProcessingStore(_ storeId: String) -> Bool {
        return isProcessing && activeJobId(for: storeId) != nil
    }

    // MARK: - Main Processing (Job-Based)

    /// Process store aisle images using async job with polling
    /// 1. Upload images to S3
    /// 2. Create extraction job via GraphQL
    /// 3. Poll for completion
    /// - Parameters:
    ///   - images: Array of image data to upload
    ///   - storeId: The store to map products for
    /// - Returns: Completed job with stats
    func processStoreAisles(images: [Data], storeId: String) async throws -> AisleExtractionJob {
        isProcessing = true
        processingStatus = "Starting..."
        currentPhase = 0
        lastError = nil
        currentJob = nil
        secondsUntilNextPoll = 0

        do {
            // ========================================
            // UPLOAD: Upload images to S3
            // ========================================
            var imageKeys: [String] = []
            if !images.isEmpty {
                for (index, imageData) in images.enumerated() {
                    processingStatus = "Uploading image \(index + 1) of \(images.count)..."
                    logger.info("[UPLOAD] Uploading image \(index + 1)/\(images.count), size: \(imageData.count) bytes")
                    let key = try await uploadImage(imageData, storeId: storeId)
                    imageKeys.append(key)
                    logger.info("[UPLOAD] Uploaded: \(key)")
                }
            }

            guard !imageKeys.isEmpty else {
                throw AisleExtractionError.processingFailed("No images to process")
            }

            // ========================================
            // CREATE JOB: Create extraction job
            // ========================================
            processingStatus = "Creating extraction job..."
            logger.info("[JOB] Creating aisle extraction job for store \(storeId) with \(imageKeys.count) images")

            let jobId = try await createJob(storeId: storeId, imageKeys: imageKeys)
            logger.info("[JOB] Created job: \(jobId)")

            // Save active job for persistence (can resume if app is closed)
            saveActiveJob(storeId: storeId, jobId: jobId)

            // ========================================
            // POLL: Wait for job completion
            // ========================================
            processingStatus = "Processing..."
            let completedJob = try await pollJobUntilComplete(jobId: jobId, storeId: storeId)

            logger.info("[JOB] Job completed: \(completedJob.entriesExtracted ?? 0) entries, \(completedJob.mappingsCreated ?? 0) mappings")

            return completedJob

        } catch {
            lastError = error.localizedDescription
            clearActiveJob(storeId: storeId)
            resetProcessingState()
            logger.error("[ERROR] Processing failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Reset processing state to idle
    private func resetProcessingState() {
        isProcessing = false
        processingStatus = ""
        currentPhase = 0
        secondsUntilNextPoll = 0
        currentJob = nil
    }

    // MARK: - Job Management

    /// Create a new aisle extraction job via GraphQL mutation
    private func createJob(storeId: String, imageKeys: [String]) async throws -> String {
        let jobId = UUID().uuidString

        let document = """
        mutation CreateAisleExtractionJob($input: CreateAisleExtractionJobInput!) {
            createAisleExtractionJob(input: $input) {
                id
                status
            }
        }
        """

        let input: [String: Any] = [
            "id": jobId,
            "storeId": storeId,
            "status": "PENDING",
            "imageKeys": imageKeys
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            guard case .object(let root) = json,
                  case .object(let jobResult) = root["createAisleExtractionJob"],
                  case .string(let createdId) = jobResult["id"] else {
                throw AisleExtractionError.processingFailed("Failed to parse job creation response")
            }
            return createdId

        case .failure(let error):
            logger.error("[JOB] Failed to create job: \(error)")
            throw error
        }
    }

    /// Poll for job completion with countdown updates for UI
    private func pollJobUntilComplete(jobId: String, storeId: String) async throws -> AisleExtractionJob {
        while true {
            // Update countdown for UI
            for i in (1...pollIntervalSeconds).reversed() {
                secondsUntilNextPoll = i
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let job = try await fetchJob(jobId: jobId)
            currentJob = job
            processingStatus = job.detail ?? job.phaseLabel ?? "Processing..."
            currentPhase = job.phase ?? 0

            logger.info("[POLL] Job \(jobId) status: \(job.status), phase: \(job.phase ?? 0), detail: \(job.detail ?? "none")")

            switch job.status {
            case "COMPLETE":
                // Job finished successfully - clean up
                clearActiveJob(storeId: storeId)
                resetProcessingState()
                return job
            case "FAILED":
                let errorMsg = job.lastError ?? "Unknown error"
                clearActiveJob(storeId: storeId)
                resetProcessingState()
                // Check if this is an API key configuration error
                if AisleExtractionError.isApiKeyError(errorMsg) {
                    throw AisleExtractionError.apiKeyNotConfigured
                }
                throw AisleExtractionError.processingFailed(errorMsg)
            default:
                // Continue polling for PENDING, EXTRACTING, MATCHING, APPLYING
                continue
            }
        }
    }

    /// Fetch job status via GraphQL query
    private func fetchJob(jobId: String) async throws -> AisleExtractionJob {
        let document = """
        query GetAisleExtractionJob($id: ID!) {
            getAisleExtractionJob(id: $id) {
                id
                storeId
                status
                phase
                phaseLabel
                detail
                retryCount
                lastError
                entriesExtracted
                mappingsCreated
                highConfidence
                lowConfidence
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["id": jobId],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
            guard case .object(let root) = json,
                  case .object(let jobData) = root["getAisleExtractionJob"] else {
                throw AisleExtractionError.processingFailed("Job not found")
            }
            return parseJob(jobData)

        case .failure(let error):
            logger.error("[POLL] Failed to fetch job: \(error)")
            throw error
        }
    }

    /// Parse job from GraphQL response
    private func parseJob(_ obj: [String: JSONValue]) -> AisleExtractionJob {
        var id = ""
        if case .string(let v) = obj["id"] { id = v }

        var storeId = ""
        if case .string(let v) = obj["storeId"] { storeId = v }

        var status = "PENDING"
        if case .string(let v) = obj["status"] { status = v }

        var phase: Int?
        if case .number(let v) = obj["phase"] { phase = Int(v) }

        var phaseLabel: String?
        if case .string(let v) = obj["phaseLabel"] { phaseLabel = v }

        var detail: String?
        if case .string(let v) = obj["detail"] { detail = v }

        var retryCount: Int?
        if case .number(let v) = obj["retryCount"] { retryCount = Int(v) }

        var lastError: String?
        if case .string(let v) = obj["lastError"] { lastError = v }

        var entriesExtracted: Int?
        if case .number(let v) = obj["entriesExtracted"] { entriesExtracted = Int(v) }

        var mappingsCreated: Int?
        if case .number(let v) = obj["mappingsCreated"] { mappingsCreated = Int(v) }

        var highConfidence: Int?
        if case .number(let v) = obj["highConfidence"] { highConfidence = Int(v) }

        var lowConfidence: Int?
        if case .number(let v) = obj["lowConfidence"] { lowConfidence = Int(v) }

        return AisleExtractionJob(
            id: id,
            storeId: storeId,
            status: status,
            phase: phase,
            phaseLabel: phaseLabel,
            detail: detail,
            retryCount: retryCount,
            lastError: lastError,
            entriesExtracted: entriesExtracted,
            mappingsCreated: mappingsCreated,
            highConfidence: highConfidence,
            lowConfidence: lowConfidence
        )
    }

    // MARK: - Phase 3: Smart Merge (Legacy - kept for manual merge if needed)

    /// Apply mappings with smart merge logic
    /// - Only updates if new_confidence > existing_confidence
    /// - Never overwrites user overrides (userAisleOverride != nil)
    func applyMappingsWithSmartMerge(_ newMappings: [LLMMappingResult], storeId: String) async throws -> MergeStats {
        isProcessing = true
        currentPhase = 3
        processingStatus = "Phase 3: Applying mappings..."
        lastError = nil

        defer {
            isProcessing = false
            processingStatus = ""
            currentPhase = 0
        }

        logger.info("[PHASE 3] Starting smart merge for \(newMappings.count) mappings")

        var updated = 0
        var skippedUserOverride = 0
        var skippedLowerConfidence = 0

        // Fetch existing mappings for this store
        processingStatus = "Phase 3: Loading existing mappings..."
        let existingMappings = try await fetchExistingMappings(storeId: storeId)
        logger.info("[PHASE 3] Found \(existingMappings.count) existing mappings")

        let existingByProductId = Dictionary(uniqueKeysWithValues: existingMappings.compactMap { mapping -> (String, ProductAisleMapping)? in
            guard let productId = mapping.productId else { return nil }
            return (productId, mapping)
        })

        for (index, newMapping) in newMappings.enumerated() {
            if index % 20 == 0 {
                processingStatus = "Phase 3: Processing \(index + 1) of \(newMappings.count)..."
            }

            if let existing = existingByProductId[newMapping.productId] {
                // Check for user override - never overwrite
                if existing.hasUserOverride {
                    skippedUserOverride += 1
                    continue
                }

                // Check confidence - only update if higher
                let existingConfidence = existing.confidence ?? 0
                if newMapping.confidence <= existingConfidence {
                    skippedLowerConfidence += 1
                    continue
                }

                // Update existing mapping
                try await updateMapping(
                    id: existing.id,
                    aisleId: newMapping.aisleId,
                    confidence: newMapping.confidence,
                    reasoning: newMapping.reasoning
                )
                updated += 1
            } else {
                // Create new mapping
                try await createMapping(
                    productId: newMapping.productId,
                    storeId: storeId,
                    aisleId: newMapping.aisleId,
                    confidence: newMapping.confidence,
                    reasoning: newMapping.reasoning
                )
                updated += 1
            }
        }

        let stats = MergeStats(
            updated: updated,
            skippedUserOverride: skippedUserOverride,
            skippedLowerConfidence: skippedLowerConfidence
        )

        logger.info("[PHASE 3] Merge complete: \(updated) updated, \(skippedUserOverride) skipped (user), \(skippedLowerConfidence) skipped (lower conf)")

        return stats
    }

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

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            logger.info("Updated user override for mapping \(mappingId)")
        case .failure(let error):
            logger.error("Failed to update user override: \(error)")
            throw error
        }
    }

    // MARK: - Private: Storage

    /// Upload image to S3 storage
    private func uploadImage(_ imageData: Data, storeId: String) async throws -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let imageKey = "\(storagePrefix)/\(storeId)/\(timestamp).jpg"

        let uploadTask = Amplify.Storage.uploadData(
            path: .fromString(imageKey),
            data: imageData,
            options: .init(contentType: "image/jpeg")
        )

        _ = try await uploadTask.value
        return imageKey
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

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
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

        case .failure(let error):
            throw error
        }
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

        let response = try await Amplify.API.mutate(request: request)

        if case .failure(let error) = response {
            throw error
        }
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

        let response = try await Amplify.API.mutate(request: request)

        if case .failure(let error) = response {
            throw error
        }
    }

    // MARK: - Single Product Aisle Inference

    /// Result from AI aisle inference for a single product
    struct AisleInferenceResult {
        var suggestedAisle: String
        let confidence: Double
        let reasoning: String
    }

    /// Infer aisle for a single product using AI and existing store mappings
    /// - Parameters:
    ///   - productName: Display name of the product
    ///   - normalizedName: Normalized name for matching
    ///   - productId: Optional product ID
    ///   - storeId: Store to infer aisle for
    /// - Returns: AI suggestion with confidence and reasoning
    func inferProductAisle(
        productName: String,
        normalizedName: String,
        productId: String?,
        storeId: String
    ) async throws -> AisleInferenceResult {
        logger.info("[INFER] Requesting aisle inference for '\(productName)' in store \(storeId)")

        let document = """
        mutation InferProductAisle(
            $storeId: ID!,
            $productName: String!,
            $normalizedName: String!,
            $productId: ID
        ) {
            inferProductAisle(
                storeId: $storeId,
                productName: $productName,
                normalizedName: $normalizedName,
                productId: $productId
            ) {
                success
                suggestedAisle
                confidence
                reasoning
                error
            }
        }
        """

        var variables: [String: Any] = [
            "storeId": storeId,
            "productName": productName,
            "normalizedName": normalizedName
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

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            guard case .object(let root) = json,
                  case .object(let result) = root["inferProductAisle"],
                  case .boolean(let success) = result["success"] else {
                throw AisleExtractionError.parseFailed("Invalid response format")
            }

            if !success {
                var errorMsg = "Inference failed"
                if case .string(let e) = result["error"] {
                    errorMsg = e
                }
                // Check if this is an API key configuration error
                if AisleExtractionError.isApiKeyError(errorMsg) {
                    throw AisleExtractionError.apiKeyNotConfigured
                }
                throw AisleExtractionError.processingFailed(errorMsg)
            }

            guard case .string(let aisle) = result["suggestedAisle"],
                  case .string(let reasoning) = result["reasoning"] else {
                throw AisleExtractionError.parseFailed("Missing aisle or reasoning in response")
            }

            var confidence: Double = 0.5
            if case .number(let c) = result["confidence"] {
                confidence = c
            }

            logger.info("[INFER] Result: aisle=\(aisle), confidence=\(confidence)")

            return AisleInferenceResult(
                suggestedAisle: aisle,
                confidence: confidence,
                reasoning: reasoning
            )

        case .failure(let error):
            logger.error("[INFER] GraphQL error: \(error)")
            throw error
        }
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

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
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

        case .failure(let error):
            logger.error("[INFER-BATCH] GraphQL error: \(error)")
            throw error
        }
    }

    /// Save batch inference results to database
    /// Reuses existing createMappingFromInference for each item
    func saveBatchInferenceResults(
        items: [BatchInferenceInput],
        results: [String: AisleInferenceResult],
        storeId: String
    ) async throws -> Int {
        var savedCount = 0

        // Only persist an aisle the store actually declares. Inference used to be
        // able to invent one ("Not mapped (likely Baking/Dry Goods aisle)") and it
        // was saved and then rendered as a section header.
        let store = await StoreService.shared.householdStores.first(where: { $0.id == storeId })
        let validAisleIds: Set<String> = Set(
            (store?.aisleLayout.map { $0.id } ?? []) + (store?.aisleLayout.map { $0.name } ?? [])
        )

        for item in items {
            guard let result = results[item.id] else { continue }
            guard validAisleIds.isEmpty || validAisleIds.contains(result.suggestedAisle) else {
                print("[INFER] Discarding invented aisle \(result.suggestedAisle) for \(item.productName)")
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
                savedCount += 1
            } catch {
                logger.error("[INFER-BATCH] Failed to save mapping for '\(item.productName)': \(error)")
                // Continue with other items
            }
        }

        logger.info("[INFER-BATCH] Saved \(savedCount) of \(items.count) mappings")
        return savedCount
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

        let document = """
        mutation UpsertProductAisleMapping(
            $id: String!, $storeId: ID!, $aisleId: String!,
            $normalizedName: String, $productId: ID,
            $confidence: Float, $source: String, $reasoning: String, $mappedAt: AWSDateTime
        ) {
            upsertProductAisleMapping(
                id: $id, storeId: $storeId, aisleId: $aisleId,
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

        let response = try await Amplify.API.mutate(request: request)

        if case .failure(let error) = response {
            throw error
        }

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
