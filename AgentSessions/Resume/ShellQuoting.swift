import Foundation

/// Shared shell-quoting utilities used by all resume command builders.
enum ShellQuoting {
    /// Wraps a string in single quotes, escaping existing single quotes using POSIX convention.
    static func quote(_ string: String) -> String {
        if string.isEmpty { return "''" }
        if !string.contains("'") { return "'\(string)'" }
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Quotes only when the string contains shell metacharacters.
    /// Produces cleaner output for copy-paste commands.
    private static let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./~+@:"))

    static func quoteIfNeeded(_ string: String) -> String {
        if string.isEmpty { return "''" }
        if string.unicodeScalars.allSatisfy({ safeChars.contains($0) }) { return string }
        return quote(string)
    }
}
