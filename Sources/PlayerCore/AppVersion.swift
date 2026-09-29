import Foundation

/// Packaging reads VERSION; UI and service identification read that same value.
public enum AppVersion {
    public static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    public static let label = current.map { "v" + $0 } ?? "开发版"
}
