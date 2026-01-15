import Foundation

struct Store: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let chain: String
    let address: String
    let city: String
    let state: String
    let zip: String
    var latitude: Double?
    var longitude: Double?
    let aisles: [Aisle]

    init(
        id: String = UUID().uuidString,
        name: String,
        chain: String,
        address: String,
        city: String,
        state: String,
        zip: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        aisles: [Aisle] = []
    ) {
        self.id = id
        self.name = name
        self.chain = chain
        self.address = address
        self.city = city
        self.state = state
        self.zip = zip
        self.latitude = latitude
        self.longitude = longitude
        self.aisles = aisles
    }

    var fullAddress: String {
        "\(address), \(city), \(state) \(zip)"
    }
}

// MARK: - Preview Helpers
extension Store {
    static var preview: Store {
        Store(
            id: "store1",
            name: "Stop & Shop Stamford",
            chain: "Stop & Shop",
            address: "123 Main St",
            city: "Stamford",
            state: "CT",
            zip: "06902",
            latitude: 41.0534,
            longitude: -73.5387,
            aisles: Aisle.previewList
        )
    }
}
