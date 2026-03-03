import Foundation
import SwiftUI
import Amplify
import AWSCognitoAuthPlugin
import AWSAPIPlugin
import AWSS3StoragePlugin
import AWSPluginsCore

@MainActor
class AmplifyService: ObservableObject {
    static let shared = AmplifyService()

    @Published var isConfigured: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: AuthUser?
    @Published var currentHouseholdId: String? {
        didSet {
            // Persist householdId locally
            if let householdId = currentHouseholdId {
                UserDefaults.standard.set(householdId, forKey: "currentHouseholdId")
                // Also write a user-scoped cache so it survives signOut and can be
                // restored if the same user signs back in (even if getUser fails).
                if let userId = currentUser?.userId {
                    UserDefaults.standard.set(householdId, forKey: "cachedHouseholdId")
                    UserDefaults.standard.set(userId, forKey: "cachedUserId")
                }
            } else {
                UserDefaults.standard.removeObject(forKey: "currentHouseholdId")
                // Intentionally do NOT clear cachedHouseholdId/cachedUserId here —
                // they persist across signOut so the same user can recover on next login.
            }
        }
    }

    private init() {}

    // MARK: - Configuration

    func configure() async {
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.add(plugin: AWSAPIPlugin(modelRegistration: AmplifyModels()))
            try Amplify.add(plugin: AWSS3StoragePlugin())

            #if DEBUG
            try Amplify.configure(with: .resource(named: "amplify_outputs_dev"))
            print("Amplify configured for DEVELOPMENT (sandbox)")
            #else
            try Amplify.configure(with: .resource(named: "amplify_outputs_prod"))
            print("Amplify configured for PRODUCTION")
            #endif

            isConfigured = true

            // Check current auth session
            await checkAuthSession()
        } catch {
            print("Failed to configure Amplify: \(error)")
        }
    }

    // MARK: - Authentication

    private func checkAuthSession() async {
        do {
            let session = try await Amplify.Auth.fetchAuthSession()

            if session.isSignedIn {
                // Verify tokens are still valid by attempting to get credentials
                if let cognitoSession = session as? AuthCognitoTokensProvider {
                    do {
                        _ = try cognitoSession.getCognitoTokens().get()
                    } catch {
                        print("Auth tokens expired or invalid: \(error)")
                        isAuthenticated = false
                        try? await signOut()
                        return
                    }
                }

                isAuthenticated = true
                currentUser = try await Amplify.Auth.getCurrentUser()
                await fetchOrCreateUserProfile()
            } else {
                isAuthenticated = false
            }
        } catch {
            print("Failed to fetch auth session: \(error)")
            isAuthenticated = false
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        let userAttributes = [
            AuthUserAttribute(.email, value: email),
            AuthUserAttribute(.name, value: displayName)
        ]
        let options = AuthSignUpRequest.Options(userAttributes: userAttributes)

        let result = try await Amplify.Auth.signUp(username: email, password: password, options: options)

        if case .confirmUser = result.nextStep {
            print("Confirmation code sent to \(email)")
        }
    }

    func confirmSignUp(email: String, code: String) async throws {
        let result = try await Amplify.Auth.confirmSignUp(for: email, confirmationCode: code)

        if result.isSignUpComplete {
            print("Sign up confirmed for \(email)")
        }
    }

    func signIn(email: String, password: String) async throws {
        // Do NOT call signOut() here before signIn() — doing so causes the Amplify API plugin
        // to lose its auth interceptor state and fall back to API key for subsequent requests,
        // resulting in "Not Authorized" on all queries even with fresh credentials.
        // checkAuthSession() already calls signOut() when tokens are expired, so by the time
        // the user reaches the login screen, the session is already cleared.
        let result = try await Amplify.Auth.signIn(username: email, password: password)

        if result.isSignedIn {
            currentUser = try await Amplify.Auth.getCurrentUser()
            await fetchOrCreateUserProfile()
            isAuthenticated = true
        } else {
            // Handle cases where sign-in is not yet complete
            switch result.nextStep {
            case .confirmSignInWithNewPassword:
                throw AmplifyError.unknown("Password reset required. Please use 'Forgot Password' to set a new password.")
            case .confirmSignInWithSMSMFACode:
                throw AmplifyError.unknown("MFA verification required but not supported yet.")
            case .confirmSignInWithCustomChallenge:
                throw AmplifyError.unknown("Additional verification required.")
            case .resetPassword:
                throw AmplifyError.unknown("Password reset required. Please use 'Forgot Password' to set a new password.")
            case .confirmSignUp:
                throw AmplifyError.unknown("Account not yet confirmed. Please check your email for a confirmation code.")
            default:
                throw AmplifyError.unknown("Sign in incomplete. Please try again.")
            }
        }
    }

    func signOut() async throws {
        _ = await Amplify.Auth.signOut()
        isAuthenticated = false
        currentUser = nil
        currentHouseholdId = nil
        UserCache.shared.clear()
    }

    func resetPassword(for email: String) async throws {
        _ = try await Amplify.Auth.resetPassword(for: email)
    }

    func confirmResetPassword(for email: String, with newPassword: String, confirmationCode: String) async throws {
        try await Amplify.Auth.confirmResetPassword(for: email, with: newPassword, confirmationCode: confirmationCode)
    }

    // MARK: - User Profile

    private func fetchOrCreateUserProfile() async {
        guard let user = currentUser else { return }

        do {
            let document = """
            query GetUser($id: ID!) {
                getUser(id: $id) {
                    id
                    email
                    displayName
                    householdId
                    profileColor
                    profilePattern
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["id": user.userId],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let userData) = root["getUser"] {
                    // User exists - cache them regardless of householdId
                    if case .string(let displayName) = userData["displayName"] {
                        var profileColor: String? = nil
                        var profilePattern: String? = nil
                        if case .string(let color) = userData["profileColor"] {
                            profileColor = color
                        }
                        if case .string(let pattern) = userData["profilePattern"] {
                            profilePattern = pattern
                        }
                        UserCache.shared.cacheUser(
                            id: user.userId,
                            displayName: displayName,
                            profileColor: profileColor,
                            profilePattern: profilePattern
                        )
                    }
                    // Set householdId if present
                    if case .string(let householdId) = userData["householdId"] {
                        self.currentHouseholdId = householdId
                    } else {
                        loadLocalHouseholdId()
                    }
                } else if case .object(let root) = json,
                          case .null = root["getUser"] {
                    // User doesn't exist in DynamoDB, create them
                    await createUserProfile()
                    loadLocalHouseholdId()
                } else {
                    // Fallback to locally stored householdId
                    loadLocalHouseholdId()
                }
            case .failure(let error):
                print("Failed to fetch user: \(error)")
                // Fallback to locally stored householdId — do NOT sign out here;
                // a fresh login should never be invalidated by a failing profile fetch.
                loadLocalHouseholdId()
            }
        } catch {
            print("Error fetching user profile: \(error)")
            // Fallback to locally stored householdId
            loadLocalHouseholdId()
        }
    }

    private func createUserProfile() async {
        guard let user = currentUser else { return }

        do {
            let email = user.username

            // Fetch user attributes from Cognito to get the display name
            let attributes = try await Amplify.Auth.fetchUserAttributes()
            guard let displayName = attributes.first(where: { $0.key == .name })?.value else {
                fatalError("User has no 'name' attribute in Cognito. Display name must be set during signup.")
            }

            let document = """
            mutation CreateUser($input: CreateUserInput!) {
                createUser(input: $input) {
                    id
                    email
                    displayName
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: [
                    "input": [
                        "id": user.userId,
                        "email": email,
                        "displayName": displayName
                    ]
                ],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.mutate(request: request)

            if case .failure(let error) = response {
                print("Failed to create user profile: \(error)")
            } else {
                print("Created user profile for \(email)")
                // Add current user to cache
                UserCache.shared.cacheUser(id: user.userId, displayName: displayName)
            }
        } catch {
            print("Error creating user profile: \(error)")
        }
    }

    private func loadLocalHouseholdId() {
        // Primary: simple stored value (set whenever currentHouseholdId is set)
        if let storedHouseholdId = UserDefaults.standard.string(forKey: "currentHouseholdId") {
            self.currentHouseholdId = storedHouseholdId
            print("Loaded householdId from UserDefaults: \(storedHouseholdId)")
            return
        }
        // Fallback: user-scoped cache that survives signOut.
        // Only restore if the cached userId matches the currently signed-in user.
        if let cachedUserId = UserDefaults.standard.string(forKey: "cachedUserId"),
           let cachedHouseholdId = UserDefaults.standard.string(forKey: "cachedHouseholdId"),
           cachedUserId == currentUser?.userId {
            self.currentHouseholdId = cachedHouseholdId
            print("Restored householdId from user-scoped cache: \(cachedHouseholdId)")
        }
    }

    // MARK: - Auth Error Handling

    /// Checks if an error is auth-related (expired/invalid tokens) and forces sign-out if so.
    func handleAuthError(_ error: Error) {
        let message = String(describing: error)
        if message.contains("Unauthorized") || message.contains("Not Authorized") || message.contains("token") || message.contains("Token") {
            print("Auth error detected, forcing sign-out: \(message)")
            Task { @MainActor in
                try? await signOut()
            }
        }
    }

    /// Overload for GraphQLResponseError — checks and forces sign-out if auth-related.
    func handleAuthError(_ error: GraphQLResponseError<JSONValue>) {
        if isAuthError(error) {
            print("GraphQL auth error detected, forcing sign-out")
            Task { @MainActor in
                try? await signOut()
            }
        }
    }

    /// Checks if a GraphQLResponseError is auth-related.
    func isAuthError(_ error: GraphQLResponseError<JSONValue>) -> Bool {
        let message: String
        switch error {
        case .error(let errors):
            message = errors.map { $0.message }.joined(separator: " ")
        case .partial(_, let errors):
            message = errors.map { $0.message }.joined(separator: " ")
        case .unknown(let msg, _, _):
            message = msg
        case .transformationError(_, let underlyingError):
            message = underlyingError.localizedDescription
        }
        return message.contains("Unauthorized") || message.contains("Not Authorized") || message.contains("token") || message.contains("Token")
    }

    // MARK: - Household

    func checkHouseholdNameAvailable(name: String) async throws -> Bool {
        let document = """
        query ListHouseholdByName($name: String!) {
            listHouseholdByName(name: $name) {
                items {
                    id
                }
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["name": name],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
            if case .object(let root) = json,
               case .object(let listResult) = root["listHouseholdByName"],
               case .array(let items) = listResult["items"] {
                return items.isEmpty
            }
            return true
        case .failure(let error):
            print("Error checking household name: \(error)")
            return true // Assume available if query fails
        }
    }

    func createHousehold(name: String) async throws -> String {
        let inviteCode = generateInviteCode()
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(24 * 60 * 60))

        let document = """
        mutation CreateHousehold($input: CreateHouseholdInput!) {
            createHousehold(input: $input) {
                id
                name
                inviteCode
                inviteCodeExpiresAt
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "name": name,
                    "inviteCode": inviteCode,
                    "inviteCodeExpiresAt": expiresAt,
                    "sequenceNumber": 0
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            if case .object(let root) = json,
               case .object(let household) = root["createHousehold"],
               case .string(let householdId) = household["id"] {
                self.currentHouseholdId = householdId
                // Update user record with householdId
                await updateUserHouseholdId(householdId)
                return householdId
            }
            throw AmplifyError.unknown("Failed to get household ID")
        case .failure(let error):
            throw error
        }
    }

    func joinHousehold(inviteCode: String) async throws {
        let document = """
        query ListHouseholdByInviteCode($inviteCode: String!) {
            listHouseholdByInviteCode(inviteCode: $inviteCode) {
                items {
                    id
                    name
                }
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["inviteCode": inviteCode],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
            if case .object(let root) = json,
               case .object(let listResult) = root["listHouseholdByInviteCode"],
               case .array(let items) = listResult["items"],
               let firstItem = items.first,
               case .object(let household) = firstItem,
               case .string(let householdId) = household["id"] {
                self.currentHouseholdId = householdId
                // Update user record with householdId
                await updateUserHouseholdId(householdId)
            } else {
                throw AmplifyError.unknown("Invalid invite code")
            }
        case .failure(let error):
            throw error
        }
    }

    private func updateUserHouseholdId(_ householdId: String) async {
        guard let user = currentUser else { return }

        // First try to update
        do {
            let updateDocument = """
            mutation UpdateUser($input: UpdateUserInput!) {
                updateUser(input: $input) {
                    id
                    householdId
                }
            }
            """

            let updateRequest = GraphQLRequest<JSONValue>(
                document: updateDocument,
                variables: [
                    "input": [
                        "id": user.userId,
                        "householdId": householdId
                    ]
                ],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.mutate(request: updateRequest)

            if case .failure(let error) = response {
                print("Update failed, trying to create user: \(error)")
                // User doesn't exist, create them with householdId
                await createUserWithHousehold(householdId)
            }
        } catch {
            print("Error updating user householdId: \(error)")
            // Try creating instead
            await createUserWithHousehold(householdId)
        }
    }

    private func createUserWithHousehold(_ householdId: String) async {
        guard let user = currentUser else { return }

        let email = user.username
        let displayName: String
        if let atIndex = email.firstIndex(of: "@") {
            displayName = String(email[..<atIndex]).capitalized
        } else {
            displayName = email
        }

        do {
            let document = """
            mutation CreateUser($input: CreateUserInput!) {
                createUser(input: $input) {
                    id
                    email
                    displayName
                    householdId
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: [
                    "input": [
                        "id": user.userId,
                        "email": email,
                        "displayName": displayName,
                        "householdId": householdId
                    ]
                ],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.mutate(request: request)

            if case .failure(let error) = response {
                print("Failed to create user with household: \(error)")
            } else {
                print("Created user \(email) with household \(householdId)")
            }
        } catch {
            print("Error creating user with household: \(error)")
        }
    }

    private func generateInviteCode() -> String {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in letters.randomElement()! })
    }

    // MARK: - Invite System

    struct HouseholdMember: Identifiable {
        let id: String
        let email: String
        let displayName: String
        let avatarUrl: String?
        let profileColor: String?
        let profilePattern: String?
        let joinedAt: Date?
    }

    struct HouseholdDetails {
        let id: String
        let name: String
        let inviteCode: String
        let inviteCodeExpiresAt: Date?
        let memberCount: Int
        let members: [HouseholdMember]
    }

    func fetchHouseholdDetails() async throws -> HouseholdDetails? {
        guard let householdId = currentHouseholdId else { return nil }

        let document = """
        query GetHousehold($id: ID!) {
            getHousehold(id: $id) {
                id
                name
                inviteCode
                inviteCodeExpiresAt
                members {
                    items {
                        id
                        email
                        displayName
                        avatarUrl
                        profileColor
                        profilePattern
                        createdAt
                    }
                }
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["id": householdId],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
            if case .object(let root) = json,
               case .object(let household) = root["getHousehold"],
               case .string(let id) = household["id"],
               case .string(let name) = household["name"],
               case .string(let inviteCode) = household["inviteCode"] {

                var expiresAt: Date? = nil
                if case .string(let expiresAtString) = household["inviteCodeExpiresAt"] {
                    expiresAt = ISO8601DateFormatter().date(from: expiresAtString)
                }

                var members: [HouseholdMember] = []
                if case .object(let membersObj) = household["members"],
                   case .array(let items) = membersObj["items"] {
                    for item in items {
                        if case .object(let memberData) = item,
                           case .string(let memberId) = memberData["id"],
                           case .string(let email) = memberData["email"],
                           case .string(let displayName) = memberData["displayName"] {

                            var avatarUrl: String? = nil
                            if case .string(let url) = memberData["avatarUrl"] {
                                avatarUrl = url
                            }

                            var profileColor: String? = nil
                            if case .string(let color) = memberData["profileColor"] {
                                profileColor = color
                            }

                            var profilePattern: String? = nil
                            if case .string(let pattern) = memberData["profilePattern"] {
                                profilePattern = pattern
                            }

                            var joinedAt: Date? = nil
                            if case .string(let createdAtString) = memberData["createdAt"] {
                                joinedAt = ISO8601DateFormatter().date(from: createdAtString)
                            }

                            // Cache each household member with their profile color/pattern
                            UserCache.shared.cacheUser(
                                id: memberId,
                                displayName: displayName,
                                avatarUrl: avatarUrl,
                                profileColor: profileColor,
                                profilePattern: profilePattern
                            )

                            members.append(HouseholdMember(
                                id: memberId,
                                email: email,
                                displayName: displayName,
                                avatarUrl: avatarUrl,
                                profileColor: profileColor,
                                profilePattern: profilePattern,
                                joinedAt: joinedAt
                            ))
                        }
                    }
                }

                return HouseholdDetails(
                    id: id,
                    name: name,
                    inviteCode: inviteCode,
                    inviteCodeExpiresAt: expiresAt,
                    memberCount: members.count,
                    members: members
                )
            }
            return nil
        case .failure(let error):
            throw error
        }
    }

    struct InviteCodeResult {
        let inviteCode: String
        let expiresAt: Date
    }

    func regenerateInviteCode() async throws -> InviteCodeResult {
        guard let householdId = currentHouseholdId else {
            throw AmplifyError.unknown("No household selected")
        }

        let document = """
        mutation RegenerateInviteCode($householdId: ID!) {
            regenerateInviteCode(householdId: $householdId) {
                inviteCode
                expiresAt
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["householdId": householdId],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            print("[DEBUG] regenerateInviteCode response: \(json)")

            // Try direct object access first (custom type returns directly)
            if case .object(let result) = json,
               case .string(let inviteCode) = result["inviteCode"],
               case .string(let expiresAtString) = result["expiresAt"],
               let expiresAt = ISO8601DateFormatter().date(from: expiresAtString) {
                return InviteCodeResult(inviteCode: inviteCode, expiresAt: expiresAt)
            }

            // Fallback: try nested under mutation name
            if case .object(let root) = json,
               case .object(let result) = root["regenerateInviteCode"],
               case .string(let inviteCode) = result["inviteCode"],
               case .string(let expiresAtString) = result["expiresAt"],
               let expiresAt = ISO8601DateFormatter().date(from: expiresAtString) {
                return InviteCodeResult(inviteCode: inviteCode, expiresAt: expiresAt)
            }

            throw AmplifyError.unknown("Failed to parse invite code response: \(json)")
        case .failure(let error):
            throw error
        }
    }

    struct SendInviteResult {
        let success: Bool
        let message: String?
    }

    func sendInviteEmail(to email: String, senderName: String) async throws -> SendInviteResult {
        guard let householdId = currentHouseholdId else {
            throw AmplifyError.unknown("No household selected")
        }

        let document = """
        mutation SendInviteEmail($householdId: ID!, $recipientEmail: String!, $senderName: String!) {
            sendInviteEmail(householdId: $householdId, recipientEmail: $recipientEmail, senderName: $senderName) {
                success
                message
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "householdId": householdId,
                "recipientEmail": email,
                "senderName": senderName
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            // Try direct object access first (custom type returns directly)
            if case .object(let result) = json,
               case .boolean(let success) = result["success"] {
                var message: String? = nil
                if case .string(let msg) = result["message"] {
                    message = msg
                }
                return SendInviteResult(success: success, message: message)
            }

            // Fallback: try nested under mutation name
            if case .object(let root) = json,
               case .object(let result) = root["sendInviteEmail"],
               case .boolean(let success) = result["success"] {
                var message: String? = nil
                if case .string(let msg) = result["message"] {
                    message = msg
                }
                return SendInviteResult(success: success, message: message)
            }
            throw AmplifyError.unknown("Failed to parse send invite response")
        case .failure(let error):
            throw error
        }
    }

    struct JoinHouseholdResult {
        let householdId: String
        let householdName: String
        let previousHouseholdId: String?
    }

    func joinHouseholdWithCode(_ inviteCode: String) async throws -> JoinHouseholdResult {
        let document = """
        mutation JoinHousehold($inviteCode: String!) {
            joinHousehold(inviteCode: $inviteCode) {
                householdId
                householdName
                previousHouseholdId
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["inviteCode": inviteCode.uppercased()],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            // Helper to parse result
            func parseResult(_ result: [String: JSONValue]) -> JoinHouseholdResult? {
                guard case .string(let householdId) = result["householdId"],
                      case .string(let householdName) = result["householdName"] else {
                    return nil
                }

                var previousId: String? = nil
                if case .string(let prevId) = result["previousHouseholdId"] {
                    previousId = prevId
                }

                return JoinHouseholdResult(
                    householdId: householdId,
                    householdName: householdName,
                    previousHouseholdId: previousId
                )
            }

            // Try direct object access first (custom type returns directly)
            if case .object(let result) = json,
               let parsed = parseResult(result) {
                self.currentHouseholdId = parsed.householdId
                NotificationCenter.default.post(name: .householdChanged, object: nil)
                return parsed
            }

            // Fallback: try nested under mutation name
            if case .object(let root) = json,
               case .object(let result) = root["joinHousehold"],
               let parsed = parseResult(result) {
                self.currentHouseholdId = parsed.householdId
                NotificationCenter.default.post(name: .householdChanged, object: nil)
                return parsed
            }

            throw AmplifyError.unknown("Failed to join household")
        case .failure(let error):
            throw error
        }
    }

    func leaveHousehold() async {
        currentHouseholdId = nil
        await updateUserHouseholdId("")
        NotificationCenter.default.post(name: .householdChanged, object: nil)
    }

    // MARK: - Profile Appearance

    func updateProfileAppearance(color: String, pattern: String) async throws {
        guard let user = currentUser else {
            throw AmplifyError.unknown("No user logged in")
        }

        let document = """
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) {
                id
                profileColor
                profilePattern
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "id": user.userId,
                    "profileColor": color,
                    "profilePattern": pattern
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            // Update the user cache with new color/pattern
            let displayName = UserCache.shared.displayName(for: user.userId)
            let avatarUrl = UserCache.shared.avatarUrl(for: user.userId)
            UserCache.shared.cacheUser(
                id: user.userId,
                displayName: displayName,
                avatarUrl: avatarUrl,
                profileColor: color,
                profilePattern: pattern
            )
            print("Updated profile appearance: \(color)/\(pattern)")
        case .failure(let error):
            throw error
        }
    }

    func fetchCurrentUserProfile() async throws -> (color: String, pattern: String) {
        guard let user = currentUser else {
            throw AmplifyError.unknown("No user logged in")
        }

        let document = """
        query GetUser($id: ID!) {
            getUser(id: $id) {
                id
                profileColor
                profilePattern
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["id": user.userId],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
            if case .object(let root) = json,
               case .object(let userData) = root["getUser"] {
                var color = "cyan"
                var pattern = "solid"

                if case .string(let profileColor) = userData["profileColor"] {
                    color = profileColor
                }
                if case .string(let profilePattern) = userData["profilePattern"] {
                    pattern = profilePattern
                }

                return (color, pattern)
            }
            return ("cyan", "solid")
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let householdChanged = Notification.Name("householdChanged")
}

// MARK: - Amplify Models Registration

struct AmplifyModels: AmplifyModelRegistration {
    public let version: String = "1"

    public func registerModels(registry: ModelRegistry.Type) {
        // Models are handled via GraphQL directly, no DataStore
    }
}

// MARK: - Error Extension

enum AmplifyError: LocalizedError {
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unknown(let message):
            return message
        }
    }
}
