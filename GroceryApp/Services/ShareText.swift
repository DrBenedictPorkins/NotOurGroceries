import Foundation

/// Turns a list into something you can drop into a message.
///
/// Plain UTF-8, one item per line. No Markdown and no tab columns: Messages,
/// WhatsApp and Mail all set proportional type, so tab stops land ragged on the
/// recipient's screen, and `**bold**` or a `|` table arrives as the literal
/// characters. A hyphen and a line break work everywhere, including Android and
/// a plain SMS fallback.
enum ShareText {

    /// The shared household list.
    ///
    /// Flat, in the order shown on screen. It is not grouped by aisle because
    /// aisles only resolve against a selected store, and the person receiving
    /// this is not walking your store — they want to know what is on the list.
    static func shoppingList(active: [GroceryItem],
                             inCart: [GroceryItem],
                             storeName: String?) -> String {
        var lines: [String] = ["\(AppIdentity.name) — Shopping list"]

        var subtitle: [String] = []
        if let storeName, !storeName.isEmpty { subtitle.append(storeName) }
        subtitle.append(active.count == 1 ? "1 item" : "\(active.count) items")
        lines.append(subtitle.joined(separator: " · "))

        if !active.isEmpty {
            lines.append("")
            lines.append(contentsOf: active.map(bullet))
        }

        // Only while a trip is running. Sharing mid-shop and hiding what is
        // already picked up invites a duplicate carton of milk.
        if !inCart.isEmpty {
            lines.append("")
            lines.append("Already in the cart")
            lines.append(contentsOf: inCart.map(bullet))
        }

        return lines.joined(separator: "\n")
    }

    /// The on-phone scratch list.
    static func quickTrip(lines quickLines: [QuickListStore.Line]) -> String {
        let remaining = quickLines.filter { !$0.checked }
        let got = quickLines.filter(\.checked)

        var lines: [String] = ["\(AppIdentity.name) — Quick trip"]
        lines.append(remaining.count == 1 ? "1 item" : "\(remaining.count) items")

        if !remaining.isEmpty {
            lines.append("")
            lines.append(contentsOf: remaining.map { "- \($0.name)" })
        }

        if !got.isEmpty {
            lines.append("")
            lines.append("Got already")
            lines.append(contentsOf: got.map { "- \($0.name)" })
        }

        return lines.joined(separator: "\n")
    }

    private static func bullet(_ item: GroceryItem) -> String {
        "- \(item.name)"
    }
}
