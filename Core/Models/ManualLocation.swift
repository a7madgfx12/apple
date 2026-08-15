import Foundation

/// A manually-selectable location (used instead of GPS when the user prefers to pick
/// a city/province directly, e.g. for a fixed home location or when GPS is unreliable).
struct ManualLocation: Codable, Identifiable, Hashable {
    let name: String
    let country: String
    let latitude: Double
    let longitude: Double

    var id: String { "\(country)-\(name)" }
    var displayName: String { "\(name)، \(country)" }

    /// Small curated preset list. Add more entries here as needed.
    static let presets: [ManualLocation] = [
        ManualLocation(name: "أضنة", country: "تركيا", latitude: 37.0000, longitude: 35.3213),
        ManualLocation(name: "إسطنبول", country: "تركيا", latitude: 41.0082, longitude: 28.9784),
        ManualLocation(name: "أنقرة", country: "تركيا", latitude: 39.9334, longitude: 32.8597),
        ManualLocation(name: "مكة المكرمة", country: "السعودية", latitude: 21.3891, longitude: 39.8579),
        ManualLocation(name: "الرياض", country: "السعودية", latitude: 24.7136, longitude: 46.6753),
        ManualLocation(name: "القاهرة", country: "مصر", latitude: 30.0444, longitude: 31.2357),
        ManualLocation(name: "عمّان", country: "الأردن", latitude: 31.9454, longitude: 35.9284),
        ManualLocation(name: "دبي", country: "الإمارات", latitude: 25.2048, longitude: 55.2708),
    ]
}
