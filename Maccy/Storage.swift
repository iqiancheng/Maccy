import Foundation
import SwiftData
import SQLite3

@MainActor
class Storage {
  static let shared = Storage()
  
  // Notification name for storage size changes
  static let storageSizeDidChangeNotification = Notification.Name("StorageSizeDidChange")

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  // Calculate total storage size including database and cache directory
  var size: String {
    var totalSize: Int64 = 0
    
    // Add database file size
    if let dbSize = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, dbSize > 0 {
      totalSize += dbSize
    }
    
    // Add cache directory size
    let cacheDir = cacheDirectory
    if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
      for file in files {
        if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          totalSize += Int64(fileSize)
        }
      }
    }
    
    guard totalSize > 0 else {
      return ""
    }
    
    return ByteCountFormatter().string(fromByteCount: totalSize)
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
    // Notify that storage size may have changed
    NotificationCenter.default.post(name: Self.storageSizeDidChangeNotification, object: nil)
  }
  
  // Clean up entire cache directory
  func clearCacheDirectory() {
    let cacheDir = cacheDirectory
    if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
      for file in files {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
  
  // Vacuum SQLite database to reclaim space
  func vacuumDatabase() {
    // SwiftData doesn't provide direct access to SQLite, so we need to use SQLite3 directly
    // We need to ensure the context has saved all changes before vacuuming
    context.processPendingChanges()
    
    let dbPath = url.path
    var db: OpaquePointer?
    
    // Open database in read-write mode
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      return
    }
    
    defer {
      sqlite3_close(db)
    }
    
    // Execute VACUUM to reclaim space
    // VACUUM rebuilds the database file, repacking it into a minimal amount of disk space
    let vacuumSQL = "VACUUM"
    var errorMessage: UnsafeMutablePointer<CChar>?
    
    let result = sqlite3_exec(db, vacuumSQL, nil, nil, &errorMessage)
    
    if result != SQLITE_OK, let errorMsg = errorMessage {
      let error = String(cString: errorMsg)
      sqlite3_free(errorMessage)
      print("Failed to vacuum database: \(error)")
    }
  }
}
