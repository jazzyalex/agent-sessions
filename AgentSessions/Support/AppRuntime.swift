import Foundation

enum AppRuntime {
    /// True when running under Xcode/`xcodebuild test`.
    static var isRunningTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

