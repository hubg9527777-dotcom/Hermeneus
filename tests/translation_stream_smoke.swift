import Foundation

@main
struct TranslationStreamSmoke {
    static func requireFailure(_ action: () throws -> Void) {
        do { try action() } catch { return }
        fatalError("Expected a failed stream to throw")
    }
    static func main() throws {
        var success = OllamaStreamState()
        let token = try success.consume(#"{"response":"Hola","done":false}"#)
        assert(token == "Hola")
        _ = try success.consume(#"{"response":"","done":true}"#)
        let final = try success.finalText()
        assert(final == "Hola")

        var truncated = OllamaStreamState()
        _ = try truncated.consume(#"{"response":"partial","done":false}"#)
        requireFailure { _ = try truncated.finalText() }

        var error = OllamaStreamState()
        requireFailure { _ = try error.consume(#"{"error":"model not found"}"#) }
        requireFailure { _ = try error.consume("broken JSON") }

        var empty = OllamaStreamState()
        _ = try empty.consume(#"{"response":"","done":true}"#)
        requireFailure { _ = try empty.finalText() }
        print("Translation stream: success, truncation, server error, malformed JSON and empty response checks passed")
    }
}
