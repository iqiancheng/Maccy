import AppKit.NSWorkspace
import AVFoundation
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewThrottler = Throttler(minimumDelay: Double(Defaults[.previewDelay]) / 1000)
  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var isSelected: Bool = false {
    didSet {
      if isSelected {
        Self.previewThrottler.throttle {
          Self.previewThrottler.minimumDelay = 0.2
          self.showPreview = true
        }
      } else {
        Self.previewThrottler.cancel()
        self.showPreview = false
      }
    }
  }
  var shortcuts: [KeyShortcut] = []
  var showPreview: Bool = false

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { item.previewableText.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  @MainActor
  func ensureThumbnailImage() {
    // Check if we have image data or image/video file path
    guard item.image != nil || item.hasImageVideoFilePath else {
      return
    }
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    thumbnailImageGenerationTask = Task { @MainActor [weak self] in
      guard let self = self else { return }
      await self.generateThumbnailImage()
    }
  }

  @MainActor
  func ensurePreviewImage() {
    // Check if we have image data or image/video file path
    guard item.image != nil || item.hasImageVideoFilePath else {
      return
    }
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    previewImageGenerationTask = Task { @MainActor [weak self] in
      guard let self = self else { return }
      await self.generatePreviewImage()
    }
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    // Untrack thumbnail when cleaned up
    History.shared.untrackThumbnail(for: id)
  }

  @MainActor
  private func generateThumbnailImage() async {
    // Check if we have a file path for image/video
    if let filePath = item.imageVideoFilePath {
      let url = URL(fileURLWithPath: filePath)
      
      // Verify file exists and is readable
      guard FileManager.default.fileExists(atPath: filePath),
            FileManager.default.isReadableFile(atPath: filePath) else {
        // Silently fail for permission issues - this is expected in sandboxed apps
        return
      }
      
      // For video files, generate thumbnail asynchronously
      if item.isVideoFile {
        if let thumbnail = await generateVideoThumbnail(from: url, size: HistoryItemDecorator.thumbnailImageSize) {
          self.thumbnailImage = thumbnail
          History.shared.trackThumbnailGenerated(for: self.id)
        }
        return
      }
      
      // For image files, load and resize asynchronously
      do {
        let imageData = try Data(contentsOf: url)
        guard let image = NSImage(data: imageData) else {
          return
        }
        self.thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
        History.shared.trackThumbnailGenerated(for: self.id)
      } catch {
        // Silently fail for permission errors - this is expected in sandboxed apps
        // Only log unexpected errors (not permission-related)
        if !error.localizedDescription.contains("permission") && !error.localizedDescription.contains("couldn't be opened") {
          History.shared.logger.warning("Failed to load image from \(filePath): \(error.localizedDescription)")
        }
      }
      return
    }
    
    // Fallback to synchronous loading for cached images
    guard let image = item.image else {
      return
    }
    thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
    // Track thumbnail generation for limiting
    History.shared.trackThumbnailGenerated(for: id)
  }

  @MainActor
  private func generatePreviewImage() async {
    // Check if we have a file path for image/video
    if let filePath = item.imageVideoFilePath {
      let url = URL(fileURLWithPath: filePath)
      
      // Verify file exists and is readable
      guard FileManager.default.fileExists(atPath: filePath),
            FileManager.default.isReadableFile(atPath: filePath) else {
        // Silently fail for permission issues - this is expected in sandboxed apps
        return
      }
      
      // For video files, generate thumbnail asynchronously
      if item.isVideoFile {
        if let thumbnail = await generateVideoThumbnail(from: url, size: HistoryItemDecorator.previewImageSize) {
          self.previewImage = thumbnail
        }
        return
      }
      
      // For image files, load and resize asynchronously
      do {
        let imageData = try Data(contentsOf: url)
        guard let image = NSImage(data: imageData) else {
          return
        }
        self.previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
      } catch {
        // Silently fail for permission errors - this is expected in sandboxed apps
        // Only log unexpected errors (not permission-related)
        if !error.localizedDescription.contains("permission") && !error.localizedDescription.contains("couldn't be opened") {
          History.shared.logger.warning("Failed to load image from \(filePath): \(error.localizedDescription)")
        }
      }
      return
    }
    
    // Fallback to synchronous loading for cached images
    guard let image = item.image else {
      return
    }
    previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
  }
  
  // Generate thumbnail from video file
  private func generateVideoThumbnail(from url: URL, size: NSSize) async -> NSImage? {
    // Check if file is readable before attempting to generate thumbnail
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      return nil
    }
    
    return await withCheckedContinuation { continuation in
      let asset = AVAsset(url: url)
      let imageGenerator = AVAssetImageGenerator(asset: asset)
      imageGenerator.appliesPreferredTrackTransform = true
      imageGenerator.requestedTimeToleranceAfter = .zero
      imageGenerator.requestedTimeToleranceBefore = .zero
      
      // Generate thumbnail at the beginning of the video
      let time = CMTime(seconds: 0, preferredTimescale: 600)
      
      imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, error in
        guard let cgImage = cgImage, error == nil else {
          continuation.resume(returning: nil)
          return
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let resizedImage = nsImage.resized(to: size)
        continuation.resume(returning: resizedImage)
      }
    }
  }

  @MainActor
  func sizeImages() {
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      await self.generatePreviewImage()
      await self.generateThumbnailImage()
    }
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: {
      DispatchQueue.main.async {
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: {
      DispatchQueue.main.async {
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }
}
