import Foundation
import Amplify

/// Service that caches the community product list locally for fast search
/// Products are fetched once and cached to disk for offline access
@MainActor
class ProductCache: ObservableObject {
    static let shared = ProductCache()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoaded = false

    private var isFetching = false
    private let cacheKey = "cached_products"
    private let cacheTimestampKey = "cached_products_timestamp"
    private let cacheExpirationSeconds: TimeInterval = 24 * 60 * 60 // 24 hours

    private init() {
        loadFromDisk()
    }

    /// Search products locally with fuzzy matching
    func search(query: String) -> [Product] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 2 else { return [] }

        let normalized = normalize(trimmed)

        // Score and sort results
        var scored: [(product: Product, score: Double)] = []

        for product in products {
            let nameScore = calculateScore(query: normalized, target: product.normalizedName)
            let aliasScore = product.aliases.map { calculateScore(query: normalized, target: $0.lowercased()) }.max() ?? 0

            let score = max(nameScore, aliasScore)
            if score >= 0.3 {
                scored.append((product, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(10)
            .map { $0.product }
    }

    /// Find a product by its ID
    func product(byId id: String) -> Product? {
        products.first { $0.id == id }
    }

    /// Find a product that matches the given name (exact or close match)
    /// Returns the product if found, nil if the item should be considered custom
    func findMatchingProduct(for name: String) -> Product? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalize(trimmed)

        // First try exact match on normalized name
        if let exactMatch = products.first(where: { $0.normalizedName == normalized }) {
            return exactMatch
        }

        // Try matching aliases exactly
        for product in products {
            if product.aliases.contains(where: { normalize($0) == normalized }) {
                return product
            }
        }

        // Try fuzzy match with high threshold (0.85+)
        var bestMatch: (product: Product, score: Double)?

        for product in products {
            let nameScore = calculateScore(query: normalized, target: product.normalizedName)
            let aliasScore = product.aliases.map { calculateScore(query: normalized, target: normalize($0)) }.max() ?? 0
            let score = max(nameScore, aliasScore)

            if score >= 0.85 && (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (product, score)
            }
        }

        return bestMatch?.product
    }

    /// Fetch all products from server and cache locally
    func fetchAllProducts() async {
        guard !isFetching else { return }

        // Check if cache is still valid
        if isLoaded && !isCacheExpired() {
            print("ProductCache: Using cached products (\(products.count) items)")
            return
        }

        isFetching = true
        defer { isFetching = false }

        print("ProductCache: Fetching products from server...")

        do {
            var allProducts: [Product] = []
            var nextToken: String? = nil

            repeat {
                let (items, token) = try await fetchProductBatch(nextToken: nextToken)
                allProducts.append(contentsOf: items)
                nextToken = token
            } while nextToken != nil

            self.products = allProducts
            self.isLoaded = true
            saveToDisk()
            print("ProductCache: Cached \(allProducts.count) products")
        } catch {
            print("ProductCache: Error fetching products: \(error)")
            // Keep using existing cache if fetch fails
        }
    }

    /// Force refresh the cache
    func refresh() async {
        clearTimestamp()
        await fetchAllProducts()
    }

    // MARK: - Private Methods

    private func fetchProductBatch(nextToken: String?) async throws -> ([Product], String?) {
        var variables: [String: Any] = ["limit": 500]
        if let token = nextToken {
            variables["nextToken"] = token
        }

        let document = """
        query ListProducts($limit: Int, $nextToken: String) {
            listProducts(limit: $limit, nextToken: $nextToken) {
                items {
                    id
                    name
                    normalizedName
                    category
                    aliases
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
                  case .object(let listResult) = root["listProducts"],
                  case .array(let items) = listResult["items"] else {
                return ([], nil)
            }

            let products = items.compactMap { parseProduct($0) }

            var token: String? = nil
            if case .string(let t) = listResult["nextToken"] {
                token = t
            }

            return (products, token)

        case .failure(let error):
            throw error
        }
    }

    private func parseProduct(_ json: JSONValue) -> Product? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let name) = obj["name"],
              case .string(let category) = obj["category"] else {
            return nil
        }

        var normalizedName = name.lowercased()
        if case .string(let value) = obj["normalizedName"] {
            normalizedName = value
        }

        var aliases: [String] = []
        if case .array(let aliasArray) = obj["aliases"] {
            aliases = aliasArray.compactMap { value in
                if case .string(let str) = value { return str }
                return nil
            }
        }

        return Product(
            id: id,
            name: name,
            normalizedName: normalizedName,
            aliases: aliases,
            category: category
        )
    }

    // MARK: - Local Search Helpers

    private func normalize(_ text: String) -> String {
        var normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove articles
        normalized = normalized.replacingOccurrences(of: "^(a |an |the )", with: "", options: .regularExpression)

        // Handle plurals
        if normalized.hasSuffix("ies") && normalized.count > 4 {
            normalized = String(normalized.dropLast(3)) + "y"
        } else if normalized.hasSuffix("oes") && normalized.count > 4 {
            normalized = String(normalized.dropLast(2))
        } else if normalized.hasSuffix("es") && normalized.count > 3 {
            let stem = String(normalized.dropLast(2))
            if stem.hasSuffix("sh") || stem.hasSuffix("ch") || stem.hasSuffix("x") ||
               stem.hasSuffix("s") || stem.hasSuffix("z") {
                normalized = stem
            }
        } else if normalized.hasSuffix("s") && normalized.count > 2 &&
                  !["hummus", "asparagus", "couscous", "citrus"].contains(normalized) {
            normalized = String(normalized.dropLast())
        }

        return normalized
    }

    private func calculateScore(query: String, target: String) -> Double {
        if query == target { return 1.0 }
        if target.hasPrefix(query) { return 0.95 }
        if target.contains(query) { return 0.85 }

        // Levenshtein-based similarity
        let distance = levenshteinDistance(query, target)
        let maxLen = max(query.count, target.count)
        guard maxLen > 0 else { return 1.0 }

        return 1.0 - (Double(distance) / Double(maxLen))
    }

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Arr = Array(s1)
        let s2Arr = Array(s2)
        let m = s1Arr.count
        let n = s2Arr.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = s1Arr[i - 1] == s2Arr[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
            }
        }

        return matrix[m][n]
    }

    // MARK: - Disk Persistence

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(products)
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
            print("ProductCache: Saved to disk")
        } catch {
            print("ProductCache: Failed to save to disk: \(error)")
        }
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else {
            print("ProductCache: No cached data on disk")
            return
        }

        do {
            products = try JSONDecoder().decode([Product].self, from: data)
            isLoaded = !products.isEmpty
            print("ProductCache: Loaded \(products.count) products from disk")
        } catch {
            print("ProductCache: Failed to load from disk: \(error)")
        }
    }

    private func isCacheExpired() -> Bool {
        let timestamp = UserDefaults.standard.double(forKey: cacheTimestampKey)
        guard timestamp > 0 else { return true }

        let elapsed = Date().timeIntervalSince1970 - timestamp
        return elapsed > cacheExpirationSeconds
    }

    private func clearTimestamp() {
        UserDefaults.standard.removeObject(forKey: cacheTimestampKey)
    }
}
