import Foundation
import Amplify
import AWSPluginsCore

/// Reads, writes and deletes item photos through the server.
///
/// The bucket grants this app nothing. Every operation asks
/// `itemImageFunction` first, which compares the household id in the key with
/// the caller's Cognito groups and hands back a short-lived presigned URL — so
/// the bytes still go straight to S3 and only the permission is brokered.
///
/// Before this, the bucket granted `get`, `write` and `delete` on the whole
/// `item-images/*` prefix to any signed-in account, and signup is open. Anyone
/// holding a key could read or delete another household's photo.
enum ItemImageService {

    struct SignedAccess {
        let url: URL?
        let s3Key: String
        let expiresIn: Int
    }

    enum ImageError: LocalizedError {
        case server(String)
        case transfer(String)

        var errorDescription: String? {
            switch self {
            case .server(let m), .transfer(let m): return m
            }
        }
    }

    // MARK: - Broker

    private static func broker(
        action: String,
        s3Key: String? = nil,
        itemId: String? = nil,
        householdId: String? = nil
    ) async throws -> SignedAccess {
        let document = """
        mutation ItemImage($action: String!, $s3Key: String, $itemId: String, $householdId: ID) {
            itemImage(action: $action, s3Key: $s3Key, itemId: $itemId, householdId: $householdId) {
                url
                s3Key
                expiresIn
            }
        }
        """

        var variables: [String: Any] = ["action": action]
        if let s3Key { variables["s3Key"] = s3Key }
        if let itemId { variables["itemId"] = itemId }
        if let householdId { variables["householdId"] = householdId }

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
            // The handler's own words — "That photo belongs to another
            // household" is worth showing. A transport failure has no words of
            // its own, so it keeps the fallback.
            throw ImageError.server(
                failure.isOffline ? "Couldn't reach that photo."
                                  : (failure.errorDescription ?? "Couldn't reach that photo.")
            )
        }

        guard case .object(let root) = json,
              case .object(let data) = root["itemImage"],
              case .string(let key) = data["s3Key"] else {
            throw ImageError.server("Couldn't get access to that photo.")
        }
        var url: URL?
        if case .string(let raw) = data["url"] { url = URL(string: raw) }
        var expires = 0
        if case .number(let n) = data["expiresIn"] { expires = Int(n) }
        return SignedAccess(url: url, s3Key: key, expiresIn: expires)
    }

    // MARK: - Operations

    /// Upload bytes for an item, returning the key the server chose.
    ///
    /// The key is the server's to pick. A client that names its own key names
    /// where the file lands, and the ownership check is only worth as much as
    /// the key being checked.
    static func upload(data: Data, itemId: String, householdId: String) async throws -> String {
        let access = try await broker(action: "upload", itemId: itemId, householdId: householdId)
        guard let url = access.url else { throw ImageError.server("Couldn't start that upload.") }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // A direct PUT to S3, so there is no Amplify error to classify — the
            // status is what we have. No response object at all means the upload
            // never completed a round trip, which is the offline case; anything
            // else answered, so it is not.
            let failure: ServiceFailure = (response as? HTTPURLResponse) == nil
                ? .offline
                : .server("Upload rejected.")
            throw ImageError.transfer(failure.sentence("The photo didn't upload"))
        }
        return access.s3Key
    }

    static func download(s3Key: String) async throws -> Data {
        let access = try await broker(action: "read", s3Key: s3Key)
        guard let url = access.url else { throw ImageError.server("Couldn't open that photo.") }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImageError.transfer("Couldn't load that photo.")
        }
        return data
    }

    /// Deleted on the server, not by a signed request.
    ///
    /// A presigned DELETE is a capability worth nothing to this app and
    /// everything to whoever else ends up holding the link.
    static func delete(s3Key: String) async throws {
        _ = try await broker(action: "delete", s3Key: s3Key)
    }
}
