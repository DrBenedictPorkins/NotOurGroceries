import SwiftUI

@main
struct GroceryAppApp: App {
    @StateObject private var amplifyService = AmplifyService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(amplifyService)
                .preferredColorScheme(.dark)
        }
    }
}
