import CoreLocation
import UIKit

/// Pixie's get_location tool. The backend model calls it when an answer depends on where the
/// user is ("near me", the weather here, directions from here) and they haven't named a place.
/// The app asks iOS for permission the first time (while in use only), takes one fix and
/// returns the area's name with coordinates rounded to about 100 m. Nothing is kept or sent
/// anywhere else; the result goes to the backend model like any tool output.
enum CurrentLocation {
    static let toolName = "get_location"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Get the user's current location: area name and approximate coordinates. Call it when the answer depends on where the user is and they haven't said a place.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
            "required": [String](),
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the answer depends on where the user is (the weather, "near me" or "nearby", directions \
    or travel time from here, local times and events) and they haven't named a place, call \
    get_location first and use the place it returns in your searches and tools. Don't call it \
    when they named a place, and don't read coordinates aloud.
    """

    /// A fix this recent is reused instead of asking for a new one.
    static let maxAge: TimeInterval = 10 * 60
    /// How long to wait for a fix.
    static let timeout: Duration = .seconds(6)

    /// What a fix becomes for the model.
    struct Place: Equatable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        /// "Yonge and Eglinton, Toronto, Ontario, Canada"; empty if the name lookup failed.
        var name: String
        /// iOS "Precise Location" off: only the town is known.
        var approximate: Bool
    }

    /// The tool's output for a place.
    static func resultText(_ place: Place) -> String {
        let lat = String(format: "%.3f", place.latitude), lon = String(format: "%.3f", place.longitude)
        let name = place.name.isEmpty ? "" : "\(place.name) "
        let within = place.approximate || place.accuracy > 1_000
            ? "approximate: only the town or area is known"
            : "within about \(max(100, Int((place.accuracy / 100).rounded()) * 100)) m"
        return "The user is in \(name)(\(lat), \(lon); \(within)). Use this place for anything nearby. The call goes on."
    }

    static let deniedText = "The user hasn't allowed Pixie to use their location. Ask them where they are; they can turn it on in the iPhone's Settings › Pixie › Location."
    static let backgroundText = "The location isn't available while Pixie is in the background and the user hasn't allowed it yet. Ask them where they are."
    static let failedText = "Couldn't get the location just now. Ask the user where they are."

    /// "Neighbourhood, City, Region, Country", skipping blanks and repeats.
    static func name(subLocality: String?, locality: String?, area: String?, country: String?) -> String {
        var parts: [String] = []
        for part in [subLocality, locality, area, country] {
            guard let part = part?.trimmingCharacters(in: .whitespaces), !part.isEmpty, !parts.contains(part) else { continue }
            parts.append(part)
        }
        return parts.joined(separator: ", ")
    }

    /// The tool's output: permission first, then one fix and its name.
    @MainActor static func locate() async -> String {
        await Locator.shared.locate()
    }
}

/// One CLLocationManager for the app: permission, one-shot fixes and the area's name.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()
    private let manager = CLLocationManager()
    private var permission: CheckedContinuation<Void, Never>?
    private var fix: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate() async -> String {
        if manager.authorizationStatus == .notDetermined {
            // iOS only shows the permission prompt to an app on screen.
            guard UIApplication.shared.applicationState == .active else { return CurrentLocation.backgroundText }
            await withCheckedContinuation { permission = $0; manager.requestWhenInUseAuthorization() }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return CurrentLocation.deniedText
        }
        var location = manager.location.flatMap { -$0.timestamp.timeIntervalSinceNow < CurrentLocation.maxAge ? $0 : nil }
        if location == nil { location = await freshFix() }
        guard let location else { return CurrentLocation.failedText }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let place = CurrentLocation.Place(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            name: CurrentLocation.name(subLocality: placemark?.subLocality, locality: placemark?.locality,
                                       area: placemark?.administrativeArea, country: placemark?.country),
            approximate: manager.accuracyAuthorization == .reducedAccuracy)
        return CurrentLocation.resultText(place)
    }

    /// One fix, or nil after the timeout.
    private func freshFix() async -> CLLocation? {
        fix?.resume(returning: nil)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: CurrentLocation.timeout)
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { fix = $0; manager.requestLocation() }
    }

    private func finish(_ location: CLLocation?) {
        fix?.resume(returning: location)
        fix = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != .notDetermined else { return }
            permission?.resume()
            permission = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated { finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
