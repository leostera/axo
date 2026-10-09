import Foundation

// Dependency-free checks for machines with Command Line Tools but no XCTest/Xcode.
@main
struct SwiftSmoke {
    static func main() throws {
        let endpoint = try RelayEndpoint("https://api.example.com")
        precondition(endpoint.socketURL.absoluteString == "wss://api.example.com/connect/phone")
        for invalid in ["http://example.com", "https://user:secret@example.com", "https://example.com/path"] {
            do { _ = try RelayEndpoint(invalid); fatalError("Accepted invalid endpoint") }
            catch ProtocolError.invalidEndpoint {}
        }
        let data = Data(#"{"type":"snapshot","sessionId":"s","viewId":"v","state":"waiting","hasEarlierMessages":false,"messages":[],"question":{"id":"q","title":"Format?","options":["JSON","Markdown"]}}"#.utf8)
        guard case .snapshot(let snapshot) = try RelayEvent.decode(data) else { fatalError("Wrong event") }
        precondition(snapshot.question?.options == ["JSON", "Markdown"])
        let encoded = try JSONEncoder().encode(PhoneCommand.prompt(id: "c", session: "s", text: "Hello"))
        let values = try JSONSerialization.jsonObject(with: encoded) as! [String: String]
        precondition(values["sessionId"] == "s" && values["id"] == "c")
        print("Swift protocol smoke checks passed")
    }
}
