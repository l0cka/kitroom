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
