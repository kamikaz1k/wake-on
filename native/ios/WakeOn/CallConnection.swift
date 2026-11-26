import Foundation
import Network

/// How a call's connection is doing, from WebRTC's ICE state, the phone's network path and the
/// call's packet statistics. Pure state, so the rules can be tested without a network.
///
/// - lost: ICE says disconnected, or the phone has no network. The call holds what the user
///   says (up to `lostLimit`) and sends it, faster than real time, once the link is back.
/// - weak: packets are being lost or the round trip is long, but audio still flows.
struct CallConnection {
    enum State: Equatable { case good, weak, lost }

    /// The call gives up and hangs up after this long without a connection. The microphone
    /// backlog holds 20 s, so nothing said in that time is dropped.
    static let lostLimit = 20.0
    /// Weak when more than this share of the received packets went missing...
    static let weakLoss = 0.08
    /// ...or the round trip takes longer than this.
    static let weakRoundTripMs = 800.0
    /// Losses are measured over this window.
    static let window = 3.0
    /// A weak connection is shown as good again only after this long without trouble.
    static let settle = 4.0

    private(set) var iceDown = false
    private(set) var pathDown = false
    private(set) var lostSince: Double?
    private(set) var weak = false
    private var goodSince: Double?
    private var samples: [(time: Double, received: Int, lost: Int)] = []

    var state: State { lostSince != nil ? .lost : weak ? .weak : .good }

    /// ICE disconnected (false) or connected again (true).
    mutating func ice(up: Bool, at time: Double) {
        iceDown = !up
        update(at: time)
    }

    /// The phone's network path went away (false) or came back (true).
    mutating func path(up: Bool, at time: Double) {
        pathDown = !up
        update(at: time)
    }

    /// Cumulative inbound packet counts and the current round trip, from a stats sample.
    mutating func stats(at time: Double, received: Int, lost: Int, roundTripMs: Double?) {
        guard lostSince == nil else { return }
        samples.append((time, received, lost))
        while let first = samples.first, time - first.time > Self.window { samples.removeFirst() }
        var trouble = (roundTripMs ?? 0) > Self.weakRoundTripMs
        if let first = samples.first, time - first.time >= Self.window * 0.5 {
            let gotten = received - first.received
            let missing = lost - first.lost
            if gotten + missing > 10 { trouble = trouble || Double(missing) / Double(gotten + missing) > Self.weakLoss }
        }
        if trouble {
            weak = true
            goodSince = nil
        } else if weak {
            if goodSince == nil { goodSince = time }
            if let since = goodSince, time - since >= Self.settle { weak = false; goodSince = nil }
        }
    }

    /// The connection has been gone too long to wait for.
    func expired(at time: Double) -> Bool {
        lostSince.map { time - $0 >= Self.lostLimit } ?? false
    }

    private mutating func update(at time: Double) {
        if iceDown || pathDown {
            if lostSince == nil { lostSince = time }
        } else if lostSince != nil {
            lostSince = nil
            // Coming back is often shaky: judge the link afresh.
            samples = []
            weak = false
            goodSince = nil
        }
    }
}

/// The phone's network path (Wi-Fi, cellular or none), for spotting a drop before ICE does
/// (ICE takes a few seconds to call a link disconnected).
@MainActor
final class NetworkPath: ObservableObject {
    static let shared = NetworkPath()
    @Published private(set) var isUp = true
    @Published private(set) var interface = "unknown"
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            let kind = path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "wired" : up ? "other" : "none"
            Task { @MainActor in
                guard let self else { return }
                if self.isUp != up { self.isUp = up }
                if self.interface != kind { self.interface = kind }
            }
        }
        monitor.start(queue: DispatchQueue(label: "pixie.network-path"))
    }
}
