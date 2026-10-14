import Dependencies
import Foundation

// Represents a single language option
struct Language: Codable, Identifiable, Hashable, Equatable {
    let code: String? // nil is used for the "Auto" option
    let name: String
    
    var id: String { code ?? "auto" }
}

// Container for the language data loaded from JSON
struct LanguageList: Codable {
    let languages: [Language]
}
