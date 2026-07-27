public enum RemoteCommandEncoder {
    public static func encode(_ request: CommandRequest) throws -> String {
        guard request.workingDirectory == nil else {
            throw HostSessionError.invalidRequest(
                "Remote working directories require a fixed adapter operation."
            )
        }

        var tokens: [String] = ["exec"]

        if !request.environment.isEmpty {
            tokens.append("/usr/bin/env")

            for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) {
                guard EnvironmentNameValidator.isValid(name) else {
                    throw HostSessionError.invalidRequest(
                        "The environment variable name \(name) is invalid."
                    )
                }
                tokens.append(try quotePOSIX("\(name)=\(value)"))
            }
        }

        tokens.append(try quotePOSIX(request.executable))
        tokens.append(contentsOf: try request.arguments.map(quotePOSIX))
        return tokens.joined(separator: " ")
    }

    public static func quotePOSIX(_ value: String) throws -> String {
        guard !value.utf8.contains(0) else {
            throw HostSessionError.invalidRequest(
                "Remote command values cannot contain null bytes."
            )
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public enum RemotePOSIXPath {
    public static func isNormalizedAbsolute(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            return false
        }
        if value == "/" {
            return true
        }
        guard !value.hasSuffix("/") else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.first?.isEmpty == true
            && components.dropFirst().allSatisfy {
                isSafeComponent($0)
            }
    }

    public static func appending(
        component: String,
        to base: String
    ) -> String? {
        guard isNormalizedAbsolute(base),
              !component.contains("/"),
              !component.contains("\0"),
              !component.contains("\n"),
              !component.contains("\r"),
              isSafeComponent(Substring(component)) else {
            return nil
        }
        return base == "/"
            ? "/" + component
            : base + "/" + component
    }

    public static func appending(
        relativePath: String,
        to base: String
    ) -> String? {
        guard isNormalizedAbsolute(base),
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\0"),
              !relativePath.contains("\n"),
              !relativePath.contains("\r") else {
            return nil
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy(isSafeComponent) else {
            return nil
        }
        return base == "/"
            ? "/" + relativePath
            : base + "/" + relativePath
    }

    public static func deletingLastComponent(
        _ value: String
    ) -> String? {
        guard isNormalizedAbsolute(value), value != "/" else {
            return nil
        }
        let components = value.split(separator: "/")
        guard components.count > 1 else {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }

    public static func lastComponent(
        _ value: String
    ) -> String? {
        guard isNormalizedAbsolute(value), value != "/" else {
            return nil
        }
        return value.split(separator: "/").last.map(String.init)
    }

    private static func isSafeComponent(
        _ value: Substring
    ) -> Bool {
        !value.isEmpty && value != "." && value != ".."
    }
}
