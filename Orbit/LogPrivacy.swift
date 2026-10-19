import Foundation

enum LogPrivacy {
    static func redact(_ text: String) -> String {
        // Defense in depth for common credential formats; server redaction remains required.
        let rules = [
            (#"(?i)(authorization\s*:\s*).*"#, "$1[redacted]"),
            (#"(?i)\bBearer\s+[^\s,;\"']+"#, "Bearer [redacted]"),
            (#"(?i)([\"']?(?:api[_-]?key|access[_-]?token|token|password|secret|cookie)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "$1[redacted]"),
            (#"AIza[\w-]{20,}|\bsk-[\w-]{16,}"#, "[redacted]")
        ]
        return rules.reduce(String(text.prefix(2000))) { value, rule in
            value.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }
}
