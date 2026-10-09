import Foundation

struct WorkspaceWindowState: Codable, Equatable {
    static let defaultSidebarWidth = 210.0
    static let minimumSidebarWidth = 180.0
    static let maximumSidebarWidth = 300.0

    var sidebarWidth: Double
    var sidebarCollapsed: Bool

    init(sidebarWidth: Double = Self.defaultSidebarWidth, sidebarCollapsed: Bool = false) {
        self.sidebarWidth = Self.validatedWidth(sidebarWidth) ?? Self.defaultSidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
    }

    static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Self.self, from: data),
              validatedWidth(state.sidebarWidth) != nil else { return Self() }
        return Self(sidebarWidth: state.sidebarWidth, sidebarCollapsed: state.sidebarCollapsed)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func validatedWidth(_ width: Double) -> Double? {
        guard width.isFinite, width >= minimumSidebarWidth else { return nil }
        return min(width, maximumSidebarWidth)
    }
}
