import Foundation

/// Statistics collected when a shopping session ends
struct ShoppingCompletionStats {
    /// Number of items that were picked up (moved to cart)
    let itemsPickedUp: Int

    /// Number of items that were not picked up (left on list)
    let itemsNotPickedUp: Int

    /// Number of items that were added during the shopping trip
    let itemsAddedDuringTrip: Int

    /// Number of custom items that made it to cart (now searchable)
    let customItemsLearned: Int

    /// The store where shopping took place
    let storeName: String

    /// When shopping started
    let startedAt: Date

    /// When shopping ended
    let endedAt: Date

    /// Duration of the shopping trip
    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    /// Formatted duration string (e.g., "45 min" or "1h 23min")
    var formattedDuration: String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)min"
        } else {
            return "\(minutes) min"
        }
    }

    /// Total items that were on the list
    var totalItems: Int {
        itemsPickedUp + itemsNotPickedUp
    }

    /// Completion percentage
    var completionPercentage: Int {
        guard totalItems > 0 else { return 100 }
        return Int((Double(itemsPickedUp) / Double(totalItems)) * 100)
    }
}
