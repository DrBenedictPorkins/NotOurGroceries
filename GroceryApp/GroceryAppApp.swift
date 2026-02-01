import SwiftUI

@main
struct GroceryAppApp: App {
    @StateObject private var amplifyService = AmplifyService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(amplifyService)
                .preferredColorScheme(.dark)
                #if DEBUG
                .overlay(alignment: .topLeading) {
                    DevIndicatorView()
                }
                #endif
        }
    }
}

#if DEBUG
struct DevIndicatorView: View {
    var body: some View {
        Text("DEV")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange)
            .cornerRadius(4)
            .padding(.leading, 8)
            .padding(.top, 4)
    }
}
#endif
