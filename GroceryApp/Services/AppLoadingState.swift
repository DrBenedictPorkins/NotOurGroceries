import Foundation
import SwiftUI

/// Represents the current loading step during app initialization
enum LoadingStep: Int, CaseIterable {
    case initializing = 0
    case configuringServices = 1
    case validatingLogin = 2
    case syncingProducts = 3
    case syncingLists = 4
    case ready = 5

    var description: String {
        switch self {
        case .initializing: return "Starting up..."
        case .configuringServices: return "Connecting to servers..."
        case .validatingLogin: return "Validating login..."
        case .syncingProducts: return "Syncing product catalog..."
        case .syncingLists: return "Syncing your lists..."
        case .ready: return "Ready!"
        }
    }

    var progress: Double {
        Double(rawValue) / Double(LoadingStep.allCases.count - 1)
    }
}

/// Represents an error that occurred during loading
struct AppError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let details: String
    let timestamp: Date
    let step: LoadingStep

    var formattedDetails: String {
        """
        Error: \(title)
        Step: \(step.description)
        Time: \(timestamp.formatted())

        Message:
        \(message)

        Technical Details:
        \(details)
        """
    }
}

/// Manages the app's loading state and error handling
@MainActor
class AppLoadingState: ObservableObject {
    static let shared = AppLoadingState()

    @Published private(set) var currentStep: LoadingStep = .initializing
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var isReady: Bool = false
    @Published var error: AppError?

    private init() {}

    func setStep(_ step: LoadingStep) {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
            if step == .ready {
                isReady = true
                // Don't auto-dismiss - wait for user to tap button
            }
        }
    }

    func dismissSplash() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isLoading = false
        }
    }

    func reportError(title: String, message: String, details: String = "") {
        error = AppError(
            title: title,
            message: message,
            details: details,
            timestamp: Date(),
            step: currentStep
        )
    }

    func clearError() {
        error = nil
    }

    func reset() {
        currentStep = .initializing
        isLoading = true
        isReady = false
        error = nil
    }
}
