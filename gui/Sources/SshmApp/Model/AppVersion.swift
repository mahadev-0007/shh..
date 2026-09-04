import Foundation

/// Version facts, read from the bundle so there is exactly one source of truth:
/// the VERSION file, which build.sh bakes into Info.plist.
enum AppVersion {
    /// Marketing version, e.g. "1.0.0".
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    /// Monotonic build number. Sparkle compares this, not the marketing string.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var display: String { "\(short) (\(build))" }

    /// Where Sparkle looks for the appcast. Overridable so a test feed can be
    /// pointed at without a rebuild.
    static var feedURL: String {
        ProcessInfo.processInfo.environment["SSHM_FEED_URL"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")
    }
}
