import Foundation
import Observation
import ServiceManagement

/// Launch at login, through `SMAppService.mainApp`. The state shown is always read back from the system after a
/// change, because the user can also change it in System Settings > General > Login Items, and a registration can
/// need their approval there.
@MainActor
@Observable
public final class LoginItem {
    public enum State: Sendable, Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings > General > Login Items.
        case requiresApproval
        /// The system cannot find the app to register (for example, a copy run from a build folder).
        case unavailable
    }

    public private(set) var state: State

    @ObservationIgnored private let service: any LoginService

    public convenience init() {
        self.init(service: SMAppService.mainApp)
    }

    init(service: any LoginService) {
        self.service = service
        state = Self.read(service)
    }

    /// Reads the state again, as when Settings appears.
    public func refresh() {
        state = Self.read(service)
    }

    /// Turns launch at login on or off, then reports the state the system actually has. Throws what the system
    /// threw; the state is read back either way.
    public func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    /// Opens System Settings > General > Login Items, where a registration that needs approval is allowed.
    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func read(_ service: any LoginService) -> State {
        switch service.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
}

/// The part of `SMAppService` that `LoginItem` uses, so tests never register the test runner as a login item.
@MainActor
protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginService {}
