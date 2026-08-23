import Foundation

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
}
