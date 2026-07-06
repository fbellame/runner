import Foundation

struct RoutePoint: Codable, Equatable, Sendable {
    let lat: Double
    let lon: Double
    let t: Date
    let afterGap: Bool
}

extension [RoutePoint] {
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> [RoutePoint] {
        (try? JSONDecoder().decode([RoutePoint].self, from: data)) ?? []
    }
}
