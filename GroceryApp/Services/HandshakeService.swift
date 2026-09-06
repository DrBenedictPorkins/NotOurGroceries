import Foundation
import Amplify
import AWSPluginsCore

/// One call that makes the app usable.
///
/// Launch used to be eight round trips — profile, catalogue, members, items,
/// stores, household, allowances, device — each with its own deadline, its own
/// failure and its own way of being half-done. Four of them ran *after* the
/// splash had gone, so on a slow connection they landed one at a time over the
/// following minute on top of a screen somebody was already using. Worse, any
/// one could fail while the rest succeeded, leaving the app assembled from a
/// mixture of what loaded and what did not, with no single place to say so.
///
/// One call has one answer. It populated the app or it did not, and "did not" is
/// a single branch — which is what turns off-grid into a decision rather than an
/// eight-way guess.
///
/// Screens still refresh their own corner: the store screen fetches its aisle
/// mappings, the allowances page re-reads itself, pull-to-refresh reloads the
/// list. This is the launch path, not the only path.
@MainActor
enum HandshakeService {
    /// What the caller still has to act on. Everything else has already been
    /// pushed into the cache that owns it.
    struct Result {
        let householdId: String?
        let shoppingStatus: String?
        let activeShopperId: String?
        let shoppingStoreId: String?
        let shoppingStartedAt: Date?
        let items: [JSONValue]
        /// False when another device has taken this account.
        let deviceStillOurs: Bool
        let activeDeviceName: String?
    }

    /// Fetch everything and distribute it. Throws `ServiceFailure`.
    static func run(deviceId: String) async throws -> Result {
        let document = """
        query Handshake($deviceId: String) {
            handshake(deviceId: $deviceId)
        }
        """
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["deviceId": deviceId],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let raw = try await API.query(request)

        // `AWSJSON` arrives as a string containing the payload.
        guard case .object(let root) = raw,
              case .string(let encoded) = root["handshake"],
              let data = encoded.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let body) = payload else {
            throw ServiceFailure.malformed("The server's answer wasn't readable.")
        }

        return apply(body)
    }

    /// Push each section into the thing that owns it, then hand back the parts
    /// that belong to the view model.
    private static func apply(_ body: [String: JSONValue]) -> Result {
        if case .array(let products) = body["products"] {
            ProductCache.shared.apply(products: products)
        }
        if case .array(let members) = body["members"] {
            UserCache.shared.apply(members: members)
        }
        if case .array(let stores) = body["stores"] {
            StoreService.shared.apply(stores: stores)
        }
        if case .object(let allowances) = body["allowances"] {
            AllowanceService.shared.apply(allowances: allowances)
        }

        var householdId: String?
        if case .object(let user) = body["user"],
           case .string(let id) = user["householdId"], !id.isEmpty {
            householdId = id
        }

        var status: String?
        var shopper: String?
        var storeId: String?
        var startedAt: Date?
        if case .object(let household) = body["household"] {
            if case .string(let value) = household["shoppingStatus"] { status = value }
            if case .string(let value) = household["activeShopperId"] { shopper = value }
            if case .string(let value) = household["shoppingStoreId"] { storeId = value }
            if case .string(let value) = household["shoppingStartedAt"] {
                startedAt = AmplifyService.parseAWSDateTime(value)
            }
        }

        var stillOurs = true
        var otherDevice: String?
        if case .object(let device) = body["device"] {
            if case .boolean(let value) = device["stillOurs"] { stillOurs = value }
            if case .string(let value) = device["activeDeviceName"] { otherDevice = value }
        }

        var items: [JSONValue] = []
        if case .array(let list) = body["items"] { items = list }

        return Result(
            householdId: householdId,
            shoppingStatus: status,
            activeShopperId: shopper,
            shoppingStoreId: storeId,
            shoppingStartedAt: startedAt,
            items: items,
            deviceStillOurs: stillOurs,
            activeDeviceName: otherDevice
        )
    }
}
