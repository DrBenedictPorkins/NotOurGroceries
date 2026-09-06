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

        // Not `API.query`. A resolver returning `AWSJSON` hands back a JSON
        // string, and Amplify's decoder frequently cannot fit that to the
        // declared response type — it reports `.transformationError` and
        // attaches the perfectly good body, which the normal path throws away.
        // `BulkImportSheet` hit exactly this with the parse Lambda; the
        // handshake is the same shape.
        let response = try await API.queryRecoveringRaw(request)

        let node: JSONValue
        switch response {
        case .success(let value):
            node = try field(from: value)
        case .failure(let graphQLError):
            switch graphQLError {
            case .partial(let value, _):
                node = try field(from: value)
            case .transformationError(let rawResponse, let apiError):
                SessionLog.shared.warning("handshake", "transformationError",
                                          ["rawBytes": "\(rawResponse.utf8.count)",
                                           "api": ServiceFailure.from(apiError).logKind])
                node = try field(fromRaw: rawResponse)
            case .error(let errors):
                throw ServiceFailure.from(graphQLErrors: errors)
            case .unknown(let description, _, _):
                throw ServiceFailure.server(description)
            }
        }

        // `AWSJSON` arrives either already parsed into an object or still a
        // string that has to be decoded. Both shapes have to work; accepting only
        // one was enough to discard a handshake the server had served in full.
        let body: [String: JSONValue]
        switch node {
        case .object(let parsed):
            body = parsed
        case .string(let encoded):
            // Peeled rather than decoded once.
            //
            // `AWSJSON` is serialised by AppSync from whatever the resolver
            // returns, so a resolver that returns `JSON.stringify(payload)` — as
            // this one did — gets stringified a second time. One decode then
            // yields the JSON text again as a `String` rather than an object, and
            // the guard that only accepted an object rejected a payload that was
            // entirely intact. The server is fixed too; this keeps working either
            // way, and would have made the bug visible in one launch instead of
            // four.
            guard let parsed = peelToObject(encoded) else {
                SessionLog.shared.error("handshake", "stringNotJSONObject",
                                        ["bytes": "\(encoded.utf8.count)"])
                throw ServiceFailure.malformed("The server's answer wasn't readable. (string)")
            }
            body = parsed
        default:
            SessionLog.shared.error("handshake", "unexpectedNodeShape", ["shape": shape(node)])
            throw ServiceFailure.malformed("The server's answer wasn't readable. (shape \(shape(node)))")
        }

        SessionLog.shared.info("handshake", "parsed", [
            "sections": body.keys.sorted().joined(separator: ","),
        ])

        return apply(body)
    }

    private static func field(from value: JSONValue) throws -> JSONValue {
        guard case .object(let root) = value else {
            SessionLog.shared.error("handshake", "rootNotObject", ["shape": shape(value)])
            throw ServiceFailure.malformed("The server's answer wasn't readable. (root)")
        }
        guard let node = root["handshake"] else {
            SessionLog.shared.error("handshake", "fieldMissing",
                                    ["keys": root.keys.sorted().joined(separator: ",")])
            throw ServiceFailure.malformed("The server's answer wasn't readable. (field)")
        }
        return node
    }

    /// Decode a JSON string, and keep decoding while the result is still a
    /// string. Bounded, because "keep going until it works" on hostile input is
    /// how you write a loop that never ends.
    private static func peelToObject(_ text: String, maxLayers: Int = 3) -> [String: JSONValue]? {
        var current = text
        for layer in 0..<maxLayers {
            guard let data = current.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return nil
            }
            switch value {
            case .object(let parsed):
                if layer > 0 {
                    SessionLog.shared.warning("handshake", "payloadWasDoubleEncoded",
                                              ["layers": "\(layer + 1)"])
                }
                return parsed
            case .string(let inner):
                current = inner
            default:
                return nil
            }
        }
        return nil
    }

    /// The *kind* of thing we got, never its content.
    private static func shape(_ value: JSONValue) -> String {
        switch value {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .null: return "null"
        }
    }

    /// The untouched response body, for when Amplify could not decode it.
    private static func field(fromRaw raw: String) throws -> JSONValue {
        guard let data = raw.data(using: .utf8),
              let whole = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            SessionLog.shared.error("handshake", "rawUndecodable", ["bytes": "\(raw.utf8.count)"])
            throw ServiceFailure.malformed("The server's answer wasn't readable. (raw)")
        }
        guard case .object(let envelope) = whole, let dataNode = envelope["data"] else {
            SessionLog.shared.error("handshake", "rawNoDataNode", ["shape": shape(whole)])
            throw ServiceFailure.malformed("The server's answer wasn't readable. (envelope)")
        }
        return try field(from: dataNode)
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
