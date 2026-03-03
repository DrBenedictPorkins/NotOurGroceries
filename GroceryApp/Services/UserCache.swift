import Foundation
import Amplify

/// Cached user information for display purposes
struct CachedUser {
    let id: String
    let displayName: String
    let avatarUrl: String?
    let profileColor: String?
    let profilePattern: String?
}

/// Service that caches user display names for dynamic lookup
/// Items store only userId - display names are resolved at render time
@MainActor
class UserCache: ObservableObject {
    static let shared = UserCache()

    @Published private(set) var users: [String: CachedUser] = [:]
    private var isFetching = false

    private init() {}

    /// Get display name for a user ID - returns fallback if not cached
    func displayName(for userId: String) -> String {
        if let user = users[userId] {
            return user.displayName
        }
        // Return a safe fallback instead of crashing
        // This can happen during sign out or if user data hasn't loaded yet
        return "User"
    }

    /// Get avatar URL for a user ID
    func avatarUrl(for userId: String) -> String? {
        users[userId]?.avatarUrl
    }

    /// Get profile color for a user ID - defaults to "cyan"
    func profileColor(for userId: String) -> String {
        users[userId]?.profileColor ?? "cyan"
    }

    /// Get profile pattern for a user ID - defaults to "solid"
    func profilePattern(for userId: String) -> String {
        users[userId]?.profilePattern ?? "solid"
    }

    /// Check if user is cached
    func hasUser(_ userId: String) -> Bool {
        users[userId] != nil
    }

    /// Fetch all users for a household and cache them
    func fetchUsersForHousehold(_ householdId: String) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            let document = """
            query ListUserByHouseholdId($householdId: ID!) {
                listUserByHouseholdId(householdId: $householdId) {
                    items {
                        id
                        displayName
                        avatarUrl
                        profileColor
                        profilePattern
                    }
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["householdId": householdId],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let listResult) = root["listUserByHouseholdId"],
                   case .array(let items) = listResult["items"] {
                    for item in items {
                        if let user = parseUser(item) {
                            users[user.id] = user
                        }
                    }
                }
            case .failure(let error):
                print("UserCache: Failed to fetch users: \(error)")
            }
        } catch {
            print("UserCache: Error fetching users: \(error)")
        }
    }

    /// Fetch a single user by ID and cache them
    func fetchUser(_ userId: String) async {
        guard !hasUser(userId) else { return }

        do {
            let document = """
            query GetUser($id: ID!) {
                getUser(id: $id) {
                    id
                    displayName
                    avatarUrl
                    profileColor
                    profilePattern
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["id": userId],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   let userData = root["getUser"],
                   let user = parseUser(userData) {
                    users[user.id] = user
                    print("UserCache: Cached user \(user.displayName)")
                }
            case .failure(let error):
                print("UserCache: Failed to fetch user \(userId): \(error)")
            }
        } catch {
            print("UserCache: Error fetching user \(userId): \(error)")
        }
    }

    /// Add or update a user in the cache
    func cacheUser(id: String, displayName: String, avatarUrl: String? = nil, profileColor: String? = nil, profilePattern: String? = nil) {
        users[id] = CachedUser(id: id, displayName: displayName, avatarUrl: avatarUrl, profileColor: profileColor, profilePattern: profilePattern)
    }

    /// Clear the cache
    func clear() {
        users.removeAll()
    }

    // MARK: - Parsing

    private func parseUser(_ json: JSONValue) -> CachedUser? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let displayName) = obj["displayName"] else {
            return nil
        }

        var avatarUrl: String? = nil
        if case .string(let url) = obj["avatarUrl"] {
            avatarUrl = url
        }

        var profileColor: String? = nil
        if case .string(let color) = obj["profileColor"] {
            profileColor = color
        }

        var profilePattern: String? = nil
        if case .string(let pattern) = obj["profilePattern"] {
            profilePattern = pattern
        }

        return CachedUser(id: id, displayName: displayName, avatarUrl: avatarUrl, profileColor: profileColor, profilePattern: profilePattern)
    }
}
