import Foundation
import UIKit
import Amplify
import AWSPluginsCore

/// One account, one device.
///
/// `activeShopperId` holds a user id rather than a device, so the same account
/// signed in twice makes both phones believe they are the shopper: both get the
/// editable At Store screen, neither drops into observer mode, take-over is a
/// no-op against yourself, and finishing on both writes two trips whose
/// client-generated ids the server cannot recognise as the same trip. Two people
/// sharing one account behave worse than two people with two accounts, which is
/// the opposite of what a household is for.
///
/// Rather than teach the shopper slot, the outbox and the finish queue about
/// devices, the account only ever has one. Newest sign-in wins, because the
/// ordinary reason for a second device is that the first has been replaced.
@MainActor
final class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()

    /// Set when the server says another device has taken the account. The app
    /// stands down rather than waiting for Cognito's refresh token to lapse,
    /// which can be an hour away.
    @Published private(set) var supersededBy: String?

    private static let idKey = "deviceId"

    private init() {}

    /// This install's id.
    ///
    /// `identifierForVendor` on its own is not enough — it changes when the last
    /// app from this vendor is deleted, so a reinstall would look like a new
    /// device and evict a session that was never replaced. Stored on first use
    /// and kept.
    var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: Self.idKey) { return existing }
        let fresh = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.idKey)
        return fresh
    }

    /// What the other device will be told replaced it. The user's own name for
    /// their phone, which is the only name they will recognise.
    var deviceName: String { UIDevice.current.name }

    // MARK: - Calls

    /// Take the account for this device. Called on a fresh sign-in only.
    func claim() async {
        _ = await call(action: "claim")
    }

    /// Do we still hold it? Called on launch and on every return to the
    /// foreground.
    ///
    /// A failure answers nothing, so it must not evict: offline, this is exactly
    /// the situation off-grid exists for, and signing somebody out because the
    /// check could not run would be the very bug we spent today removing.
    func verify() async {
        guard let result = await call(action: "verify") else { return }
        if result.stillOurs {
            supersededBy = nil
        } else {
            supersededBy = result.activeDeviceName ?? "another device"
        }
    }

    func clearSuperseded() { supersededBy = nil }

    /// The launch handshake answers this too, so it does not need its own round
    /// trip on the path where every other answer already arrived.
    func noteSuperseded(by name: String?) {
        supersededBy = name ?? "another device"
    }

    private struct Result { let stillOurs: Bool; let activeDeviceName: String? }

    private func call(action: String) async -> Result? {
        let document = """
        mutation ClaimDevice($action: String!, $deviceId: String!, $deviceName: String) {
            claimDevice(action: $action, deviceId: $deviceId, deviceName: $deviceName) {
                stillOurs
                activeDeviceName
            }
        }
        """
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["action": action, "deviceId": deviceId, "deviceName": deviceName],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )
        do {
            let json = try await API.mutate(request)
            guard case .object(let root) = json,
                  case .object(let node) = root["claimDevice"],
                  case .boolean(let stillOurs) = node["stillOurs"] else { return nil }
            var name: String? = nil
            if case .string(let n) = node["activeDeviceName"] { name = n }
            return Result(stillOurs: stillOurs, activeDeviceName: name)
        } catch {
            print("DeviceRegistry: \(action) failed — \(ServiceFailure.from(error))")
            return nil
        }
    }
}
