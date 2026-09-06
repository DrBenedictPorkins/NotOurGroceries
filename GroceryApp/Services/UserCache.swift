import Foundation
import Amplify
import AWSPluginsCore

/// Cached user information for display purposes
struct CachedUser {
    let id: String
    let displayName: String
    let avatarUrl: String?
    let profileColor: String?
}

/// Service that caches user display names for dynamic lookup
/// Items store only userId - display names are resolved at render time
@MainActor
class UserCache: ObservableObject {
    static let shared = UserCache()

    @Published private(set) var users: [String: CachedUser] = [:]
    private var isFetching = false
    /// Ids already asked about, so a cache miss in a view body asks once rather
    /// than on every redraw.
    private var requestedLookups: Set<String> = []

    private init() {}

    /// Get display name for a user ID - returns fallback if not cached
    ///
    /// A miss used to be permanent until something else refreshed the whole
    /// cache. It filled on launch and on a full refresh, so anybody who joined
    /// after that — including a member who left and came back — had their items
    /// attributed to "User" on everybody else's phone until they happened to
    /// pull to refresh. Now a miss asks, once, and the row corrects itself when
    /// the answer lands.
    func displayName(for userId: String) -> String {
        if let user = users[userId] {
            return user.displayName
        }
        resolveLater(userId)
        return "User"
    }

    /// Ask about an id we do not know, at most once, off the render pass.
    ///
    /// Called from view bodies, so it must not fetch inline and must not ask
    /// again on every redraw — a list of twenty unknown rows would otherwise
    /// issue twenty queries per frame.
    private func resolveLater(_ userId: String) {
        guard !userId.isEmpty, !requestedLookups.contains(userId) else { return }
        requestedLookups.insert(userId)
        Task { @MainActor in
            await fetchUser(userId)
            // Let it be asked again later if the answer never arrived; a member
            // who joins after a failed lookup should not stay "User" forever.
            if !hasUser(userId) { requestedLookups.remove(userId) }
        }
    }

    /// Get avatar URL for a user ID
    func avatarUrl(for userId: String) -> String? {
        users[userId]?.avatarUrl
    }

    /// Get profile color for a user ID - defaults to "cyan"
    func profileColor(for userId: String) -> String {
        users[userId]?.profileColor ?? "cyan"
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

            let json = try await API.query(request)

            if case .object(let root) = json,
               case .object(let listResult) = root["listUserByHouseholdId"],
               case .array(let items) = listResult["items"] {
                for item in items {
                    if let user = parseUser(item) {
                        users[user.id] = user
                    }
                }
            }
        } catch let failure as ServiceFailure {
            // Display names only: a miss renders as "User" and `resolveLater`
            // asks again, so a failed warm costs nothing and is not worth an alert.
            print("UserCache: couldn't fetch users — \(failure.errorDescription ?? "unknown")")
        } catch {
            print("UserCache: couldn't fetch users — \(error)")
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
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["id": userId],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let json = try await API.query(request)

            if case .object(let root) = json,
               let userData = root["getUser"],
               let user = parseUser(userData) {
                users[user.id] = user
                print("UserCache: Cached user \(user.displayName)")
            }
        } catch let failure as ServiceFailure {
            // Same no-op as above, and `resolveLater` clears the id so the next
            // render of that row asks once more.
            print("UserCache: couldn't fetch user \(userId) — \(failure.errorDescription ?? "unknown")")
        } catch {
            print("UserCache: couldn't fetch user \(userId) — \(error)")
        }
    }

    /// Add or update a user in the cache
    func cacheUser(id: String, displayName: String, avatarUrl: String? = nil, profileColor: String? = nil) {
        users[id] = CachedUser(id: id, displayName: displayName, avatarUrl: avatarUrl, profileColor: profileColor)
    }

    /// Clear the cache
    func clear() {
        users.removeAll()
    }

    // MARK: - Parsing

    /// Take a whole household's members from the launch handshake.
    ///
    /// Same parser as the standalone query, so the two paths cannot drift.
    func apply(members: [JSONValue]) {
        for item in members {
            if let user = parseUser(item) { users[user.id] = user }
        }
    }

    func parseUser(_ json: JSONValue) -> CachedUser? {
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

        return CachedUser(id: id, displayName: displayName, avatarUrl: avatarUrl, profileColor: profileColor)
    }
}
