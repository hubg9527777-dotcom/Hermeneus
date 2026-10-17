import Foundation

/// An HTTP 200 is not proof that a streamed inference finished successfully.
struct OllamaStreamState {
    private(set) var completed = false
    private(set) var text = ""

    mutating func consume(_ line: String) throws -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.failure("翻译服务返回了无法读取的数据，请重试。")
        }
        if let error = object["error"] as? String { throw Self.failure("翻译失败：\(error)") }
        if object["done"] as? Bool == true { completed = true }
        guard let token = object["response"] as? String, !token.isEmpty else { return nil }
        text += token
        return token
    }

    func finalText() throws -> String {
        guard completed else { throw Self.failure("翻译连接中断，请重新翻译此句。") }
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw Self.failure("模型没有返回翻译，请检查模型选择。") }
        return final
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OllamaError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
