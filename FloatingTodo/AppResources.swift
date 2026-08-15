import Foundation

enum AppResources {
    static func url(forResource name: String, withExtension extensionName: String) -> URL? {
        if let bundledURL = Bundle.main.url(forResource: name, withExtension: extensionName) {
            return bundledURL
        }

        // SwiftPM 调试运行时没有标准 app Resources 目录，回退到源码资源目录。
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension(extensionName)
    }
}
