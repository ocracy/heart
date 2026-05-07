import Foundation

struct DevTask: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var command: String
    var cwd: String
    var port: Int?
    var autoStart: Bool
    var folder: String?

    init(id: String = UUID().uuidString,
         name: String,
         command: String,
         cwd: String,
         port: Int? = nil,
         autoStart: Bool = false,
         folder: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.port = port
        self.autoStart = autoStart
        self.folder = folder
    }
}
