import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  // Directory for storing images and files externally
  var cacheDirectory: URL {
    let dir = URL.applicationSupportDirectory.appending(path: "Maccy/Cache")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
      // Ensure cache directory exists
      _ = cacheDirectory
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  // Generate unique file path for storing image/file
  func generateCacheFilePath(for type: String, extension ext: String) -> URL {
    let fileName = UUID().uuidString + "." + ext
    return cacheDirectory.appending(path: fileName)
  }

  // Clean up file when item is deleted
  func deleteCacheFile(at path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
  }
}
