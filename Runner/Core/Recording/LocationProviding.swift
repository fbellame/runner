import CoreLocation

@MainActor
protocol LocationProviding: AnyObject {
    var delegate: LocationProvidingDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
    func startUpdates()
    func stopUpdates()
}

@MainActor
protocol LocationProvidingDelegate: AnyObject {
    func didUpdate(locations: [CLLocation])
    func didChangeAuthorization(_ status: CLAuthorizationStatus)
    func didFail(_ error: Error)
}
