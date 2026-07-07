import CoreLocation

@MainActor
protocol LocationProviding: AnyObject {
    var delegate: LocationProvidingDelegate? { get set }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    func requestWhenInUseAuthorization()
    func requestTemporaryFullAccuracy(purposeKey: String)
    func startUpdates()
    func stopUpdates()
}

@MainActor
protocol LocationProvidingDelegate: AnyObject {
    func didUpdate(locations: [CLLocation])
    func didChangeAuthorization(_ status: CLAuthorizationStatus)
    func didFail(_ error: Error)
}
