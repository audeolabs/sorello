import DictationCore
@testable import MacPlatform
import ServiceManagement
import Testing

@MainActor
private final class FakeLoginService: LoginService {
    var status: SMAppService.Status
    /// What the system does on register: the status it moves to, or an error.
    var registerResult: Result<SMAppService.Status, any Error> = .success(.enabled)
    private(set) var calls: [String] = []

    init(_ status: SMAppService.Status) { self.status = status }

    func register() throws {
        calls.append("register")
        status = try registerResult.get()
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }
}

private struct Refused: Error {}

@MainActor
@Suite("Launch at login")
struct LoginItemTests {
    @Test("The system's status maps to the state shown", arguments: [
        (SMAppService.Status.enabled, LoginItem.State.enabled), (.notRegistered, .disabled),
        (.requiresApproval, .requiresApproval), (.notFound, .unavailable),
    ])
    func mapping(status: SMAppService.Status, state: LoginItem.State) {
        #expect(LoginItem(service: FakeLoginService(status)).state == state)
    }

    @Test("Turning it on reports what the system did, including a registration that needs approval")
    func enable() throws {
        let service = FakeLoginService(.notRegistered)
        service.registerResult = .success(.requiresApproval)
        let item = LoginItem(service: service)
        try item.setEnabled(true)
        #expect(item.state == .requiresApproval)
        try item.setEnabled(false)
        #expect(item.state == .disabled)
        #expect(service.calls == ["register", "unregister"])
    }

    @Test("A refused registration is thrown and the real state is still shown")
    func refused() {
        let service = FakeLoginService(.notRegistered)
        service.registerResult = .failure(Refused())
        let item = LoginItem(service: service)
        #expect(throws: Refused.self) { try item.setEnabled(true) }
        #expect(item.state == .disabled)
    }

    @Test("A change made in System Settings shows after refresh")
    func refresh() {
        let service = FakeLoginService(.notRegistered)
        let item = LoginItem(service: service)
        service.status = .enabled
        item.refresh()
        #expect(item.state == .enabled)
    }
}

@Suite("The app in front")
struct FrontmostAppTests {
    @Test("An app is named by its bundle identifier and name")
    func named() {
        #expect(FrontmostApp.identity(bundleID: "com.example.notes", name: "Notes", pid: 20, ownPID: 10)
                == AppIdentity(bundleID: "com.example.notes", name: "Notes"))
    }

    @Test("Sorello itself, or an app without a bundle identifier, is nil")
    func unnamed() {
        #expect(FrontmostApp.identity(bundleID: "com.example.self", name: "Self", pid: 10, ownPID: 10) == nil)
        #expect(FrontmostApp.identity(bundleID: nil, name: "Tool", pid: 20, ownPID: 10) == nil)
        #expect(FrontmostApp.identity(bundleID: "", name: "Tool", pid: 20, ownPID: 10) == nil)
    }

    @Test("A missing name falls back to the bundle identifier")
    func fallbackName() {
        #expect(FrontmostApp.identity(bundleID: "com.example.tool", name: nil, pid: 20, ownPID: 10)?.name
                == "com.example.tool")
    }

    @Test("Reading the real app in front works without any permission")
    @MainActor
    func real() {
        _ = FrontmostApp().frontmostApp()
    }
}
