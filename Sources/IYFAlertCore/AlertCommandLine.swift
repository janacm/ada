import Foundation

public enum AlertCommand: Equatable {
    case show(URL)
    case check
    case help
}

public struct AlertCommandLineError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum AlertCommandLine {
    public static let usage = """
    Usage:
      iyf-alert <alert-url>
      iyf-alert --check

    <alert-url> is the file:// URL built by iyf-show-alert.sh.
    """

    public static func parse(_ arguments: [String]) -> Result<AlertCommand, AlertCommandLineError> {
        guard let first = arguments.first else {
            return .failure(AlertCommandLineError(message: usage))
        }

        switch first {
        case "-h", "--help", "help":
            return .success(.help)
        case "--check":
            return .success(.check)
        default:
            guard arguments.count == 1, let url = URL(string: first), !url.scheme.isNilOrEmpty else {
                return .failure(AlertCommandLineError(message: usage))
            }
            return .success(.show(url))
        }
    }
}

public let nativeCloseBridgeScript = """
(function() {
  window.iyfNative = true;
  window.close = function() {
    try {
      window.webkit.messageHandlers.iyfClose.postMessage('close');
    } catch (e) {}
  };
})();
"""

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        switch self {
        case .some(let value): return value.isEmpty
        case .none: return true
        }
    }
}
