import AppKit
import Defaults
import Sauce
import SwiftData
import Vision

@Model
class HistoryItem {
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  @MainActor
  static var availablePins: [String] {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil }
    )
    let pins = try? Storage.shared.context.fetch(descriptor).compactMap({ $0.pin })
    let assignedPins = Set(pins ?? [])
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.type == content.type && $0.value == content.value })
      }
  }

  func generateTitle() -> String {
    // For image/video files, use filename as title
    if hasImageVideoFilePath, let filePath = imageVideoFilePath {
      let url = URL(fileURLWithPath: filePath)
      let fileName = url.lastPathComponent
      if !fileName.isEmpty {
        // If image can be loaded, perform text recognition asynchronously
        if image != nil {
          Task {
            self.performTextRecognition()
          }
        }
        return fileName
      }
    }
    
    // For images that can be loaded, perform text recognition
    guard image == nil else {
      Task {
        self.performTextRecognition()
      }
      return ""
    }

    // 1k characters is trade-off for performance
    var title = previewableText.shortened(to: 1_000)

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      // For files, only show the filename (not the full path) for display
      // But the full path is still stored in filePath for preview generation
      fileURLs
        .map { $0.lastPathComponent }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    var urlPaths: Set<String> = []
    var urls: [URL] = []
    
    // First, try to get URLs from filePath (for image/video files that only store path)
    for content in contents where NSPasteboard.PasteboardType(content.type) == .fileURL {
      if let filePath = content.filePath, !urlPaths.contains(filePath) {
        urlPaths.insert(filePath)
        urls.append(URL(fileURLWithPath: filePath))
      }
    }
    
    // Also get URLs from value data (for regular file URLs)
    let dataUrls = allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
    
    // Add URLs from data that aren't already in the set
    for url in dataUrls {
      let path = url.path
      if !urlPaths.contains(path) {
        urlPaths.insert(path)
        urls.append(url)
      }
    }
    
    return urls
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  // Check if content has image/video file path
  var hasImageVideoFilePath: Bool {
    // Check fileURL type content with filePath (for copied files)
    if contents.contains(where: { content in
      NSPasteboard.PasteboardType(content.type) == .fileURL && content.filePath != nil
    }) {
      if let filePath = imageVideoFilePath {
        return true
      }
    }
    
    // Also check image content types with filePath (for cached clipboard images)
    return contents.contains { content in
      let type = NSPasteboard.PasteboardType(content.type)
      return [.png, .tiff, .jpeg, .heic].contains(type) && content.filePath != nil
    }
  }
  
  // Get image/video file path if available
  var imageVideoFilePath: String? {
    // First, check fileURL type content with filePath (for copied files)
    if let fileURLContent = contents.first(where: { content in
      NSPasteboard.PasteboardType(content.type) == .fileURL && content.filePath != nil
    }), let filePath = fileURLContent.filePath {
      let url = URL(fileURLWithPath: filePath)
      let ext = url.pathExtension.lowercased()
      let imageVideoExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "gif", "bmp", "webp", "mov", "mp4", "avi", "mkv", "m4v", "mpg", "mpeg"]
      if imageVideoExtensions.contains(ext) {
        return filePath
      }
    }
    
    // Also check image content types with filePath (for cached clipboard images)
    return contents.first(where: { content in
      let type = NSPasteboard.PasteboardType(content.type)
      if [.png, .tiff, .jpeg, .heic].contains(type), let filePath = content.filePath {
        return true
      }
      return false
    })?.filePath
  }
  
  // Check if content is a video file
  var isVideoFile: Bool {
    guard let filePath = imageVideoFilePath else { return false }
    let url = URL(fileURLWithPath: filePath)
    let ext = url.pathExtension.lowercased()
    let videoExtensions: Set<String> = ["mov", "mp4", "avi", "mkv", "m4v", "mpg", "mpeg"]
    return videoExtensions.contains(ext)
  }

  var imageData: Data? {
    // Skip video files - they need special handling
    if isVideoFile {
      return nil
    }
    
    // First try to load from external file path
    if let filePath = imageVideoFilePath {
      // Check if file is readable before attempting to load
      guard FileManager.default.isReadableFile(atPath: filePath) else {
        return nil
      }
      let url = URL(fileURLWithPath: filePath)
      return try? Data(contentsOf: url)
    }
    
    // Also check image content types with file paths
    if let imageContent = contents.first(where: { content in
      let type = NSPasteboard.PasteboardType(content.type)
      return [.tiff, .png, .jpeg, .heic].contains(type) && content.filePath != nil
    }), let filePath = imageContent.filePath {
      // Check if file is readable before attempting to load
      guard FileManager.default.isReadableFile(atPath: filePath) else {
        return nil
      }
      let url = URL(fileURLWithPath: filePath)
      return try? Data(contentsOf: url)
    }
    
    // Fallback to database storage
    var data: Data?
    data = contentData([.tiff, .png, .jpeg, .heic])
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      // Check if file is readable before attempting to load
      if FileManager.default.isReadableFile(atPath: url.path) {
        data = try? Data(contentsOf: url)
      }
    }

    return data
  }

  var image: NSImage? {
    guard let data = imageData else {
      return nil
    }

    return NSImage(data: data)
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

  private func performTextRecognition() {
    guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return
    }

    let requestHandler = VNImageRequestHandler(cgImage: cgImage)
    let request = VNRecognizeTextRequest(completionHandler: recognizeTextHandler)
    request.recognitionLevel = .fast

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
    }
  }

  private func recognizeTextHandler(request: VNRequest, error: Error?) {
    guard let observations = request.results as? [VNRecognizedTextObservation] else {
      return
    }

    let recognizedStrings = observations.compactMap { observation in
      return observation.topCandidates(1).first?.string
    }

    self.title = recognizedStrings.joined(separator: "\n")
  }
}
