import Foundation

/// ghostty vendor 主题目录的只读扫描。结果按文件名字母序排序、忽略点文件。
/// 主题文件随 bundle 由 xcodegen 的 postBuildScript 拷贝到
/// `Bundle.main.resourcePath/ghostty/themes/`。
enum ThemeCatalog {

    /// 扫描任意目录，返回文件名（非 `.` 开头）排序列表。
    static func scan(atPath path: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 运行时 bundle 内的所有主题名。懒求值，首次访问后缓存。
    static let all: [String] = {
        guard let base = Bundle.main.resourcePath else { return [] }
        let themesDir = (base as NSString).appendingPathComponent("ghostty/themes")
        return scan(atPath: themesDir)
    }()
}
