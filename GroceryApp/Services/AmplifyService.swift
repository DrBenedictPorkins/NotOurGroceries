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

            // One backend, all build configurations. With two users on an internal
            // beta, a separate sandbox bought nothing but a second schema to keep
            // in sync — and every drift between the two cost a debugging session.
            // Debug builds write to the same data the phones use; that's the point.
            try Amplify.configure(with: .resource(named: "amplify_outputs_prod"))
            print("Amplify configured for PRODUCTION")

            isConfigured = true
        } catch {
            print("Failed to configure Amplify: \(error)")
        }
    }

    // MARK: - Authentication

    /// What the token says this user may reach.
    ///
    /// Worth logging because a missing group is indistinguishable from a
    /// server problem at the call site: every query simply returns denied.
    private func logGroupClaims(_ session: AuthSession) {
        guard let provider = session as? AuthCognitoTokensProvider,
              let tokens = try? provider.getCognitoTokens().get() else { return }

        // Middle segment of the JWT, base64url, padded back to a multiple of 4.
        let parts = tokens.idToken.split(separator: ".")
        guard parts.count > 1 else { return }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let groups = json["cognito:groups"] as? [String] ?? []
        print("[AUTH] groups: \(groups.isEmpty ? "none" : groups.joined(separator: ", "))")
    }

    /// Refreshes the session and loads this user's profile.
    ///
    /// Split out of `configure()` so the launch screen can time it and name it.
    /// It is the slowest thing that happens at launch — a forced Cognito token
    /// refresh followed by a `getUser` — and while it was buried inside
    /// configuration there was no step to attribute a stall to.
    func checkAuthSession() async {
        do {
            // Force-refreshed on purpose. Household membership is a Cognito group
            // claim, and a claim only exists in a token minted after it was
            // granted — a cached token from before someone joined, was removed,
            // or was added during a migration authorises the wrong thing. The
            // failure is silent and confusing: sign-in works, every query comes
            // back denied, and it fixes itself an hour later when the token
            // happens to expire. One refresh at launch removes that whole class.
            let session = try await Amplify.Auth.fetchAuthSession(options: .forceRefresh())

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
                logGroupClaims(session)
                await fetchOrCreateUserProfile()
            } else {
                isAuthenticated = false
            }
        } catch {
            // A failed *refresh* is not the same as being signed out, and this
            // treated them as the same thing: open the app on a bad connection
            // and it dropped you at the sign-in screen as though your session
            // had ended. The tokens on this device are still there.
            //
            // So only give up on the session when the refresh actually says the
            // session is invalid. Anything that looks like the network is
            // reported and the existing session is left alone; the next launch,
            // or the next call, retries it.
            print("Failed to fetch auth session: \(error)")

            if Self.looksLikeNetworkFailure(error) {
                sessionCheckFailedOffline = true
                logWarning("auth.sessionRefreshFailed", "kept the existing session")
            } else {
                isAuthenticated = false
            }
        }
    }

    /// True when the session check failed for reasons that look like the network
    /// rather than the credentials. Read by `RootView` so a blip does not present
    /// itself as a sign-out.
    @Published var sessionCheckFailedOffline = false

    // MARK: - Off-grid

    /// Shopping with no server at all.
    ///
    /// The session could not be checked, so there is no verified token — but
    /// this device already holds the list, the stores and the aisle order from
    /// the last time it was online, and standing in a shop with no signal is
    /// precisely when that matters. Refusing to open the app because Cognito is
    /// unreachable throws away everything already on the disk.
    ///
    /// This is deliberately not `PaperMode` coming back. That was a place you
    /// went, entered by dialog, and it was deleted because it made offline
    /// mutually exclusive with shopping. This is the answer to one question,
    /// asked only after the network has already failed and only when there is
    /// genuinely something to shop from. Everything inside the app behaves as it
    /// does on any bad connection: writes queue in the `Outbox`, the header says
    /// what you are looking at, and the moment a token can be refreshed this
    /// drops away on its own.
    @Published private(set) var isOffGrid = false

    /// Whether going off-grid would show a list rather than an empty app. Asked
    /// before the offer is made, so we never offer a door into nothing.
    var canGoOffGrid: Bool {
        guard !isAuthenticated else { return false }
        guard let snapshot = LocalListStore.load(), !snapshot.items.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: "currentHouseholdId") != nil
    }

    func goOffGrid() {
        guard canGoOffGrid else { return }
        loadLocalHouseholdId()
        isOffGrid = true
        print("[AUTH] off-grid: no verified session, shopping from the local snapshot")
    }

    /// Called once a real session exists again. Nothing else clears this — the
    /// point is that it ends by itself when the network comes back, not by the
    /// person remembering to leave.
    func leaveOffGrid() {
        guard isOffGrid else { return }
        isOffGrid = false
        sessionCheckFailedOffline = false
    }

    /// Retries the session check and comes back on the grid if it works. Safe to
    /// call repeatedly; it does nothing unless we are off-grid.
    func retrySessionIfOffGrid() async {
        guard isOffGrid, NetworkStatus.shared.pathIsSatisfied else { return }
        await checkAuthSession()
        if isAuthenticated { leaveOffGrid() }
    }

    private static func looksLikeNetworkFailure(_ error: Error) -> Bool {
        if let authError = error as? AuthError {
            switch authError {
            case .service(_, _, let underlying):
                return underlying is URLError || "\(underlying as Any)".localizedCaseInsensitiveContains("network")
            default:
                break
            }
        }
        if error is URLError { return true }
        let text = "\(error)".lowercased()
        return text.contains("network") || text.contains("offline")
            || text.contains("connection") || text.contains("timed out")
    }

    private func logWarning(_ event: String, _ detail: String) {
        print("[AUTH] \(event): \(detail)")
    }

    // MARK: - AWSDateTime

    /// AppSync `AWSDateTime` parsing that accepts both shapes it arrives in.
    ///
    /// Lambdas write `new Date().toISOString()`, which always carries
    /// milliseconds ("…:23.896Z"). A bare `ISO8601DateFormatter` rejects
    /// fractional seconds and returns nil, and every call site here treated that
    /// nil as "no date" — so the invite screen showed no expiry, member rows
    /// showed no joined date, and `regenerateInviteCode`, which makes the parse a
    /// required binding, threw on every attempt and the code never changed.
    ///
    /// Both formats are accepted because this app has written both: the
    /// deprecated `createHousehold` above wrote timestamps without a fraction.
    /// The rest of the codebase already does this — see `GroceryItem.swift` and
    /// `SubscriptionService.swift`; these call sites were the outliers.
    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain = ISO8601DateFormatter()

    static func parseAWSDateTime(_ value: String) -> Date? {
        iso8601WithFraction.date(from: value) ?? iso8601Plain.date(from: value)
    }

    /// Written with milliseconds, matching what the Lambdas write.
    static func formatAWSDateTime(_ date: Date) -> String {
        iso8601WithFraction.string(from: date)
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
            // A fresh sign-in, as opposed to a restored session: the allowance
            // card shows once regardless of how much is used, so a new household
            // sees what it has before it starts. See MONETIZATION.qmd, "The nudge".
            AllowanceService.shared.showOnNextAppearance = true
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
        // The result was discarded, so this function could not fail and the
        // `catch` around its call site was decorative. Local state is still
        // cleared either way — the warning card has already promised that, and
        // leaving a half-signed-out phone would be worse — but a failed sign-out
        // is now reported rather than swallowed.
        let result = await Amplify.Auth.signOut()
        var signOutFailure: Error?
        if let cognito = result as? AWSCognitoSignOutResult {
            switch cognito {
            case .complete:
                break
            case .partial(_, _, let hostedUIError):
                // The associated values here are Cognito's own error types, not
                // `Error`, so they need wrapping before they can be thrown.
                signOutFailure = hostedUIError.map { AmplifyError.unknown("Sign out incomplete: \($0)") }
            case .failed(let error):
                signOutFailure = error
            @unknown default:
                break
            }
        }

        isAuthenticated = false
        currentUser = nil
        currentHouseholdId = nil
        UserCache.shared.clear()
        Self.clearLocalUserData()

        if let signOutFailure {
            print("[AUTH] sign out incomplete: \(signOutFailure)")
            throw signOutFailure
        }
    }

    /// Everything this account left on the device.
    ///
    /// These four stores are files in the app container, not per-account, so
    /// without this the next person to sign in inherits the last one's cached
    /// shopping list, scratch list and shopping history. On a shared or resold
    /// phone that is somebody else's data on screen.
    ///
    /// The outbox is the one that does more than embarrass: queued writes carry
    /// item ids from the previous household, and the next session would push
    /// them under its own credentials.
    ///
    /// Deliberately unconditional. A partial wipe here is worse than none —
    /// leftovers are exactly the state nobody tests.
    static func clearLocalUserData() {
        LocalListStore.clear()
        QuickListStore.shared.clear()
        Outbox.shared.clear()
        TripStats.shared.clear()
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
                        if case .string(let color) = userData["profileColor"] {
                            profileColor = color
                        }
                        UserCache.shared.cacheUser(
                            id: user.userId,
                            displayName: displayName,
                            profileColor: profileColor
                        )
                    }
                    // Repair the rows written by the old bug, on sign-in.
                    // Every account created before this stored its sub in the
                    // email column, so the household screen showed a UUID where
                    // a person's address belongs. Nobody is going to file that as
                    // a bug; it just looks broken.
                    if case .string(let storedEmail) = userData["email"],
                       !storedEmail.contains("@") {
                        await repairStoredEmail(for: user.userId)
                    }

                    // The row came back, so whatever it says about householdId
                    // is the truth — including saying nothing.
                    //
                    // This used to fall back to the cached id when the field was
                    // absent, which is right when the *query* failed and wrong
                    // when it succeeded. A member removed from their household
                    // signed in, had the household they had just been removed
                    // from restored from UserDefaults, watched the old list
                    // appear for a moment while every query came back
                    // Unauthorized, and was then signed out by handleAuthError.
                    // They could not get in at all.
                    if case .string(let householdId) = userData["householdId"], !householdId.isEmpty {
                        self.currentHouseholdId = householdId
                    } else {
                        self.currentHouseholdId = nil
                        forgetLocalHouseholdId()
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

    /// The signed-in user's address, from Cognito rather than from `username`.
    ///
    /// With an email-based pool `AuthUser.username` is the sub — a UUID — so
    /// reading the email out of it stored the UUID in the email column, and every
    /// screen that showed "their email" showed a UUID instead. All six existing
    /// users are like this. Nil when the attribute is somehow absent, so callers
    /// can decide rather than persisting a placeholder.
    private func cognitoEmail(from attributes: [AuthUserAttribute]) -> String? {
        attributes.first(where: { $0.key == .email })?.value
    }

    /// Put the real address back on a row that has a UUID in it.
    ///
    /// Only ever touches the signed-in user's own row, and only when what is
    /// stored is plainly not an email.
    private func repairStoredEmail(for userId: String) async {
        let attributes = (try? await Amplify.Auth.fetchUserAttributes()) ?? []
        guard let email = cognitoEmail(from: attributes), email.contains("@") else { return }

        let document = """
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) {
                id
                email
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": ["id": userId, "email": email]],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            if case .failure(let error) = try await Amplify.API.mutate(request: request) {
                print("Could not repair stored email: \(error)")
            }
        } catch {
            // Best effort. A failure here leaves the row as it was, and the next
            // sign-in tries again.
            print("Could not repair stored email: \(error)")
        }
    }

    private func createUserProfile() async {
        guard let user = currentUser else { return }

        do {
            // Fetch user attributes from Cognito to get the display name
            let attributes = try await Amplify.Auth.fetchUserAttributes()
            guard let displayName = attributes.first(where: { $0.key == .name })?.value else {
                fatalError("User has no 'name' attribute in Cognito. Display name must be set during signup.")
            }
            let email = cognitoEmail(from: attributes) ?? user.username

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

    /// Drop the cached household, both copies.
    ///
    /// `currentHouseholdId = nil` clears the plain key through its didSet, but
    /// the user-scoped cache is deliberately built to survive sign-out, so it
    /// would otherwise hand the same stale id back on the next launch.
    func forgetLocalHouseholdId() {
        UserDefaults.standard.removeObject(forKey: "currentHouseholdId")
        UserDefaults.standard.removeObject(forKey: "cachedHouseholdId")
        UserDefaults.standard.removeObject(forKey: "cachedUserId")
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

    /// Ask the server whether this account is still in a household.
    ///
    /// Returns nil if the question could not be answered — offline, or the
    /// query failed — so callers can tell "no household" from "don't know" and
    /// leave the app alone in the second case.
    @discardableResult
    func refreshHouseholdMembership() async -> String?? {
        guard let user = currentUser else { return nil }

        let document = """
        query GetUser($id: ID!) { getUser(id: $id) { id householdId } }
        """
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["id": user.userId],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        guard let response = try? await Amplify.API.query(request: request),
              case .success(let json) = response,
              case .object(let root) = json,
              case .object(let userData) = root["getUser"] else { return nil }

        if case .string(let householdId) = userData["householdId"], !householdId.isEmpty {
            return .some(householdId)
        }
        return .some(nil)
    }

    // MARK: - Auth Error Handling

    /// Checks if an error is auth-related (expired/invalid tokens) and forces sign-out if so.
    /// Overload for errors that aren't GraphQLResponseError — transport failures
    /// and anything else thrown out of the SDK. String-sniffing, because those
    /// types don't expose a structured auth signal.
    func isAuthError(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.contains("Unauthorized") || message.contains("Not Authorized") || message.contains("token") || message.contains("Token")
    }

    func handleAuthError(_ error: Error) {
        guard isAuthError(error) else { return }
        Task { @MainActor in
            // "Unauthorized" has two very different causes, and signing out was
            // the right answer to only one of them. A bad or expired token means
            // sign out. Being removed from your household means every
            // household-scoped query fails while your sign-in is perfectly
            // valid — and signing out on that made the app impossible to get
            // back into, because the next sign-in restored the same stale
            // household and failed the same way.
            //
            // The user's own row answers it: `allow.owner()` still lets them
            // read it with no household at all.
            switch await self.refreshHouseholdMembership() {
            case .some(.none):
                print("Auth error, and this account is in no household — dropping to setup")
                self.currentHouseholdId = nil
                self.forgetLocalHouseholdId()
                NotificationCenter.default.post(name: .householdChanged, object: nil)
            case .some(.some):
                print("Auth error with a live household — forcing sign-out")
                try? await self.signOut()
            case .none:
                // Could not ask. Offline, most likely. Leave them alone rather
                // than signing somebody out because the café wifi dropped.
                print("Auth error, membership unknown — leaving session alone")
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

    /// The message the server actually sent, rather than Amplify's wrapper.
    ///
    /// A thrown `GraphQLResponseError` describes itself as "The operation
    /// couldn't be completed. (Amplify.GraphQLResponseError<Amplify.JSONValue>
    /// error 0.)", which is what the join screen was showing people. The useful
    /// text — "That invite code doesn't work..." — is inside the errors array
    /// the whole time. Handlers are written to be read by a user, so surface
    /// what they said and keep the wrapper for the log.
    func serverMessage(from error: GraphQLResponseError<JSONValue>, fallback: String) -> String {
        let messages: [String]
        switch error {
        case .error(let errors), .partial(_, let errors):
            messages = errors.map { $0.message }
        case .unknown(let msg, _, _):
            messages = [msg]
        case .transformationError:
            messages = []
        }
        let joined = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? fallback : joined
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

    /// Superseded by `createHouseholdRemotely`, which is the only path the app
    /// uses now. Kept because the invite-code generator below is still called
    /// from elsewhere; the mutation itself writes no ownerId and creates no
    /// Cognito group, so a household made this way is unreadable by its creator.
    @available(*, deprecated, message: "Use createHouseholdRemotely — this creates no group and no owner")
    func createHousehold(name: String) async throws -> String {
        let inviteCode = generateInviteCode()
        // Ten minutes, matching the Lambdas that own this everywhere else —
        // `householdMembershipFunction` and `regenerateInviteCodeFunction`. See
        // the note there for why.
        let expiresAt = Self.formatAWSDateTime(Date().addingTimeInterval(10 * 60))

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
                    // Whoever creates it owns it, and ownership never moves. The
                    // only thing it permits is removing other members.
                    "ownerId": currentUser?.userId ?? "",
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

    /// Superseded by `joinHouseholdWithCode`, which is the only path that can
    /// still work: this one queries the Household row directly, and those are
    /// scoped to their Cognito group, so a person who is not yet a member reads
    /// nothing. It also never checked `inviteCodeExpiresAt`.
    @available(*, deprecated, message: "Use joinHouseholdWithCode — this cannot read a household you are not in")
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
                        "householdId": householdId,
                        // Mirrors householdId. The read rule matches on this
                        // because householdId is a GSI key and DynamoDB will not
                        // accept an auth filter on a key attribute.
                        "householdGroup": householdId
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

        // Same trap as createUserProfile: `username` is the sub on an email pool,
        // and deriving a display name from it produced a UUID for a name.
        let attributes = (try? await Amplify.Auth.fetchUserAttributes()) ?? []
        let email = cognitoEmail(from: attributes) ?? user.username
        let displayName: String
        if let named = attributes.first(where: { $0.key == .name })?.value, !named.isEmpty {
            displayName = named
        } else if let atIndex = email.firstIndex(of: "@") {
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
                        "householdId": householdId,
                        "householdGroup": householdId
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
        let joinedAt: Date?
    }

    struct HouseholdDetails {
        let id: String
        let name: String
        let inviteCode: String
        let inviteCodeExpiresAt: Date?
        let memberCount: Int
        let members: [HouseholdMember]
        /// Nil for households created before ownership existed. Those simply
        /// have nobody who can remove anybody.
        let ownerId: String?
    }

    func fetchHouseholdDetails() async throws -> HouseholdDetails? {
        guard let householdId = currentHouseholdId else { return nil }

        let document = """
        query GetHousehold($id: ID!) {
            getHousehold(id: $id) {
                id
                name
                ownerId
                inviteCode
                inviteCodeExpiresAt
                members {
                    items {
                        id
                        email
                        displayName
                        avatarUrl
                        profileColor
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
                    expiresAt = Self.parseAWSDateTime(expiresAtString)
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

                            var joinedAt: Date? = nil
                            if case .string(let createdAtString) = memberData["createdAt"] {
                                joinedAt = Self.parseAWSDateTime(createdAtString)
                            }

                            // Cache each household member with their profile colour
                            UserCache.shared.cacheUser(
                                id: memberId,
                                displayName: displayName,
                                avatarUrl: avatarUrl,
                                profileColor: profileColor
                            )

                            members.append(HouseholdMember(
                                id: memberId,
                                email: email,
                                displayName: displayName,
                                avatarUrl: avatarUrl,
                                profileColor: profileColor,
                                joinedAt: joinedAt
                            ))
                        }
                    }
                }

                let ownerId: String? = {
                    if case .string(let value) = household["ownerId"], !value.isEmpty { return value }
                    return nil
                }()

                return HouseholdDetails(
                    id: id,
                    name: name,
                    inviteCode: inviteCode,
                    inviteCodeExpiresAt: expiresAt,
                    memberCount: members.count,
                    members: members,
                    ownerId: ownerId
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
               let expiresAt = Self.parseAWSDateTime(expiresAtString) {
                return InviteCodeResult(inviteCode: inviteCode, expiresAt: expiresAt)
            }

            // Fallback: try nested under mutation name
            if case .object(let root) = json,
               case .object(let result) = root["regenerateInviteCode"],
               case .string(let inviteCode) = result["inviteCode"],
               case .string(let expiresAtString) = result["expiresAt"],
               let expiresAt = Self.parseAWSDateTime(expiresAtString) {
                return InviteCodeResult(inviteCode: inviteCode, expiresAt: expiresAt)
            }

            throw AmplifyError.unknown("Failed to parse invite code response: \(json)")
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
                // The Lambda just granted the group claim; the token in memory
                // was issued before it, so refresh before anything queries.
                await refreshSessionForNewClaims()
                self.currentHouseholdId = parsed.householdId
                NotificationCenter.default.post(name: .householdChanged, object: nil)
                return parsed
            }

            // Fallback: try nested under mutation name
            if case .object(let root) = json,
               case .object(let result) = root["joinHousehold"],
               let parsed = parseResult(result) {
                await refreshSessionForNewClaims()
                self.currentHouseholdId = parsed.householdId
                NotificationCenter.default.post(name: .householdChanged, object: nil)
                return parsed
            }

            throw AmplifyError.unknown("Failed to join household")
        case .failure(let error):
            throw AmplifyError.unknown(serverMessage(
                from: error,
                fallback: "Couldn't join that household. Check the code and try again."
            ))
        }
    }

    /// What came back from a membership change.
    struct MembershipResult {
        let householdId: String
        let householdDeleted: Bool
        let remainingMembers: Int
        let inviteCode: String?
        /// Starting stores that could not be created for a brand-new household.
        /// Empty on every other membership action.
        var startingStoresFailed: [String] = []
    }

    /// Membership is a Cognito group claim, and a claim only exists in a token
    /// that was issued after it was granted. The session in memory predates the
    /// change, so without this the user is in the household and cannot read a
    /// single row of it until the token happens to expire.
    private func refreshSessionForNewClaims() async {
        do {
            _ = try await Amplify.Auth.fetchAuthSession(options: .forceRefresh())
        } catch {
            print("Could not refresh session after membership change: \(error)")
        }
    }

    /// Remove somebody else. Owner only, enforced in the Lambda.
    @discardableResult
    func removeMember(_ memberId: String) async throws -> MembershipResult {
        try await manageMembership(action: "remove", memberId: memberId)
    }

    /// Leave the household. Anyone, owner included. If nobody is left, the
    /// household and its data are deleted.
    @discardableResult
    func leaveHouseholdRemotely() async throws -> MembershipResult {
        let result = try await manageMembership(action: "leave", memberId: nil)
        currentHouseholdId = nil
        UserDefaults.standard.removeObject(forKey: "cachedHouseholdId")
        NotificationCenter.default.post(name: .householdChanged, object: nil)
        return result
    }

    /// Create a household with the caller as owner.
    ///
    /// Server-side because three things must not come from the client: the
    /// owner, the invite code, and the Cognito group the creator needs in order
    /// to read what they just made.
    func createHouseholdRemotely(name: String) async throws -> MembershipResult {
        var result = try await manageMembership(action: "create", name: name)
        await refreshSessionForNewClaims()
        currentHouseholdId = result.householdId
        // Once, here. A household starts with a plain supermarket and a small
        // shop with no aisles; both are then ordinary stores it can rename or
        // delete, which is only true because nothing puts them back.
        //
        // Seeding used to swallow its own failures, which left a new household
        // permanently with no stores and told nobody. The household itself is
        // fine either way, so this is carried back to the caller as something
        // to say rather than thrown.
        result.startingStoresFailed = await StoreService.shared.seedStartingStores(householdId: result.householdId)
        NotificationCenter.default.post(name: .householdChanged, object: nil)
        return result
    }

    /// Delete this account: the household membership, the User row, and the
    /// Cognito sign-in.
    ///
    /// Required by App Store guideline 5.1.1(v) — an app that creates accounts
    /// has to delete them from inside the app. Self-service only; the mutation
    /// takes no member id, so this can never be pointed at somebody else.
    ///
    /// Items they added stay with the household, which is the promise the Leave
    /// dialog already makes. If they were the last member, the household and its
    /// data go with them, exactly as leaving would.
    @discardableResult
    func deleteAccount() async throws -> MembershipResult {
        let result = try await manageMembership(action: "deleteAccount", memberId: nil)

        // The sign-in no longer exists, so the local session is meaningless.
        // Clearing before signOut because signOut against a deleted user can
        // fail, and the on-device leftovers are the part that actually matters.
        currentHouseholdId = nil
        UserDefaults.standard.removeObject(forKey: "cachedHouseholdId")
        UserDefaults.standard.removeObject(forKey: "cachedUserId")
        Self.clearLocalUserData()
        try? await Amplify.Auth.signOut()
        isAuthenticated = false
        currentUser = nil
        NotificationCenter.default.post(name: .householdChanged, object: nil)

        return result
    }

    private func manageMembership(action: String,
                                  memberId: String? = nil,
                                  name: String? = nil) async throws -> MembershipResult {
        let document = """
        mutation ManageHouseholdMembership($action: String!, $memberId: ID, $name: String) {
            manageHouseholdMembership(action: $action, memberId: $memberId, name: $name) {
                householdId
                householdDeleted
                remainingMembers
                inviteCode
            }
        }
        """

        var variables: [String: Any] = ["action": action]
        variables["memberId"] = memberId ?? NSNull()
        variables["name"] = name ?? NSNull()

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        switch try await Amplify.API.mutate(request: request) {
        case .success(let json):
            guard case .object(let root) = json,
                  case .object(let payload) = root["manageHouseholdMembership"] else {
                throw AmplifyError.unknown("Unexpected response")
            }
            let deleted: Bool = { if case .boolean(let b) = payload["householdDeleted"] { return b }; return false }()
            let remaining: Int = {
                if case .number(let n) = payload["remainingMembers"] { return Int(n) }
                return 0
            }()
            let id: String = { if case .string(let v) = payload["householdId"] { return v }; return "" }()
            let code: String? = { if case .string(let v) = payload["inviteCode"] { return v }; return nil }()
            return MembershipResult(householdId: id, householdDeleted: deleted,
                                    remainingMembers: remaining, inviteCode: code)
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

    func updateProfileAppearance(color: String) async throws {
        guard let user = currentUser else {
            throw AmplifyError.unknown("No user logged in")
        }

        let document = """
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) {
                id
                profileColor
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "id": user.userId,
                    "profileColor": color
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            // Update the user cache with the new colour
            let displayName = UserCache.shared.displayName(for: user.userId)
            let avatarUrl = UserCache.shared.avatarUrl(for: user.userId)
            UserCache.shared.cacheUser(
                id: user.userId,
                displayName: displayName,
                avatarUrl: avatarUrl,
                profileColor: color
            )
            print("Updated profile colour: \(color)")
        case .failure(let error):
            throw error
        }
    }

    func fetchCurrentUserProfile() async throws -> String {
        guard let user = currentUser else {
            throw AmplifyError.unknown("No user logged in")
        }

        let document = """
        query GetUser($id: ID!) {
            getUser(id: $id) {
                id
                profileColor
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
                if case .string(let profileColor) = userData["profileColor"] {
                    return profileColor
                }
                return "cyan"
            }
            return "cyan"
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
