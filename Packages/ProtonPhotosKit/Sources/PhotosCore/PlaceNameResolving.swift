public protocol PlaceNameResolving: Sendable {
    func placeName(latitude: Double, longitude: Double) async -> String?
}
