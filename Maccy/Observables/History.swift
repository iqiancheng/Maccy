// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var selectedItem: HistoryItemDecorator? {
    willSet {
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [self] in
        // Throttler already runs on main queue, use assumeIsolated to satisfy compiler
        MainActor.assumeIsolated {
          if searchQuery.isEmpty {
            // Reset to recent items - reload if needed
            resetToRecentItems()
            AppState.shared.selection = unpinnedItems.first?.id
          } else {
            // Use database search for better performance
            updateItemsFromSearch(searchQuery)
            AppState.shared.highlightFirst()
          }

          AppState.shared.popup.needsResize = true
        }
      }
    }
  }
  
  // Reset to recent items when search is cleared
  @MainActor
  private func resetToRecentItems() {
    // Check if we have enough recent items loaded
    let recentUnpinnedCount = loadedItems.values.filter(\.isUnpinned).count
    let initialLimit = 60
    
    if recentUnpinnedCount < initialLimit {
      // Reload recent items from database
      Task {
        do {
          // Load pinned items
          let pinnedDescriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.pin != nil },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
          )
          let pinned = try Storage.shared.context.fetch(pinnedDescriptor)
          
          // Load recent unpinned items
          var unpinnedDescriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.pin == nil },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
          )
          unpinnedDescriptor.fetchLimit = initialLimit
          let unpinned = try Storage.shared.context.fetch(unpinnedDescriptor)
          
          // Combine and sort
          let allLoaded = sorter.sort(pinned + unpinned)
          loadedItems = Dictionary(uniqueKeysWithValues: allLoaded.map { item in
            let decorator = HistoryItemDecorator(item)
            return (decorator.id, decorator)
          })
          
          // Update items list
          items = Array(loadedItems.values).sorted { decorator1, decorator2 in
            sorter.compare(decorator1.item, decorator2.item)
          }
          
          // Update visible range
          visibleRange = 0..<min(initialLimit, items.count)
          
          updateShortcuts()
          AppState.shared.popup.needsResize = true
        } catch {
          // Fallback to existing loaded items
          items = Array(loadedItems.values).sorted { decorator1, decorator2 in
            sorter.compare(decorator1.item, decorator2.item)
          }
        }
      }
    } else {
      // We have enough items, just reset the display
      items = Array(loadedItems.values).sorted { decorator1, decorator2 in
        sorter.compare(decorator1.item, decorator2.item)
      }
    }
  }
  
  @MainActor
  private func updateItemsFromSearch(_ query: String) {
    // Search in entire database globally - no limit
    // Fetch all items from database for global search
    var descriptor = FetchDescriptor<HistoryItem>(
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    // No fetchLimit - search entire database
    
    guard let allItems = try? Storage.shared.context.fetch(descriptor) else {
      items = []
      return
    }
    
    // Filter by search query using in-memory search
    // For very large datasets, this is still efficient as we only create decorators for matching items
    let decorators = allItems.map { HistoryItemDecorator($0) }
    let searchResults = search.search(string: query, within: decorators)
    
    // Keep pinned items and search results in memory
    // Don't clear all loaded items - keep recent items for when search is cleared
    let resultIds = Set(searchResults.map { $0.object.id })
    let pinnedIds = Set(loadedItems.values.filter(\.isPinned).map(\.id))
    
    // Keep: pinned items, search results, and recent items (first 60 unpinned)
    let recentUnpinned = Array(loadedItems.values)
      .filter(\.isUnpinned)
      .sorted { sorter.compare($0.item, $1.item) }
      .prefix(60)
      .map(\.id)
    
    let keepIds = resultIds.union(pinnedIds).union(Set(recentUnpinned))
    loadedItems = loadedItems.filter { keepIds.contains($0.key) }
    
    // Add search results to cache
    for result in searchResults {
      let item = result.object
      item.highlight(query, result.ranges)
      loadedItems[item.id] = item
    }
    
    items = searchResults.map { $0.object }
    updateUnpinnedShortcuts()
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // Windowed loading: only load items as needed
  // - `items` stores only visible history items, updated during a search
  // - `loadedItems` caches recently loaded items for performance
  @ObservationIgnored
  private var loadedItems: [UUID: HistoryItemDecorator] = [:]
  
  // Track total count without loading all items
  @ObservationIgnored
  private var totalCount: Int = 0
  
  // Virtual scrolling: only keep visible items + buffer
  // Buffer size: keep ~30 items above and below visible area
  private let visibleBufferSize = 30
  @ObservationIgnored
  private var visibleRange: Range<Int> = 0..<0
  
  // Track items with thumbnail images loaded (for limiting to 99)
  @ObservationIgnored
  private var itemsWithThumbnails: [UUID: Date] = [:]
  private let maxThumbnailCount = 99

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    // Deduplicate pins before loading
    deduplicatePins()
    
    // Update total count
    totalCount = try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
    
    // Load initial batch of items (pinned + recent unpinned)
    let pinnedDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    let pinned = try Storage.shared.context.fetch(pinnedDescriptor)
    
    // Load initial visible window: only load what's needed for first screen
    // Estimate ~20-30 items visible, load 50-60 for buffer
    let initialLimit = 60
    var unpinnedDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    unpinnedDescriptor.fetchLimit = initialLimit
    let unpinned = try Storage.shared.context.fetch(unpinnedDescriptor)
    
    // Combine and sort
    let allLoaded = sorter.sort(pinned + unpinned)
    loadedItems = Dictionary(uniqueKeysWithValues: allLoaded.map { item in
      let decorator = HistoryItemDecorator(item)
      return (decorator.id, decorator)
    })
    
    items = Array(loadedItems.values).sorted { decorator1, decorator2 in
      sorter.compare(decorator1.item, decorator2.item)
    }
    
    // Set initial visible range
    visibleRange = 0..<min(initialLimit, items.count)

    // Limit history size for images/files only (text can be unlimited)
    limitHistorySizeIfNeeded()

    updateShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }
  
  // Load more items when scrolling (windowed loading)
  @MainActor
  func loadMore(offset: Int, limit: Int = 50) async throws -> [HistoryItemDecorator] {
    var descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit
    
    let results = try Storage.shared.context.fetch(descriptor)
    let decorators = results.map { HistoryItemDecorator($0) }
    
    // Cache loaded items
    for decorator in decorators {
      loadedItems[decorator.id] = decorator
    }
    
    // Update visible range
    let newEnd = min(offset + limit, totalCount)
    visibleRange = offset..<newEnd
    
    // Periodically clean up items outside visible buffer
    // Only cleanup if we have too many items loaded
    if loadedItems.count > 150 {
      cleanupItemsOutsideVisibleRange()
    }
    
    // Update items list
    items = Array(loadedItems.values).sorted { decorator1, decorator2 in
      sorter.compare(decorator1.item, decorator2.item)
    }
    
    return decorators
  }
  
  // Clean up items that are far outside visible range
  @MainActor
  private func cleanupItemsOutsideVisibleRange() {
    // Keep pinned items always
    let pinnedItems = loadedItems.values.filter(\.isPinned)
    let pinnedIds = Set(pinnedItems.map(\.id))
    
    // Maximum items to keep in memory (visible + buffer)
    // Keep ~100 items total (30 visible + 70 buffer)
    let maxItemsToKeep = 100
    
    if loadedItems.count <= maxItemsToKeep {
      return // No cleanup needed
    }
    
    // Get sorted unpinned items
    let sortedUnpinned = Array(loadedItems.values)
      .filter(\.isUnpinned)
      .sorted { sorter.compare($0.item, $1.item) }
    
    // Keep only the most recent items (they're more likely to be visible)
    let itemsToKeep = sortedUnpinned.prefix(maxItemsToKeep - pinnedItems.count)
    let keepIds = Set(itemsToKeep.map(\.id)).union(pinnedIds)
    
    // Remove items not in keep list
    let itemsToRemove = loadedItems.values.filter { !keepIds.contains($0.id) }
    for item in itemsToRemove {
      item.cleanupImages()
      loadedItems.removeValue(forKey: item.id)
    }
  }
  
  // Check if we need to load more items
  var hasMoreItems: Bool {
    let loadedCount = loadedItems.values.filter(\.isUnpinned).count
    return loadedCount < totalCount
  }

  @MainActor
  private func limitHistorySizeIfNeeded() {
    // Only limit if we exceed size setting
    let maxSize = Defaults[.size]
    guard totalCount > maxSize else { return }
    
    // Get unpinned items sorted by date, oldest first
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .forward)]
    )
    
    if let allUnpinned = try? Storage.shared.context.fetch(descriptor) {
      let toDelete = allUnpinned.prefix(totalCount - maxSize)
      for item in toDelete {
        // Only delete items with images/files, keep text items
        let hasImageOrFile = item.contents.contains { content in
          let type = NSPasteboard.PasteboardType(content.type)
          return [.png, .tiff, .jpeg, .heic, .fileURL].contains(type)
        }
        if hasImageOrFile {
          if let decorator = loadedItems.values.first(where: { $0.item == item }) {
            delete(decorator)
          } else {
            cleanup(HistoryItemDecorator(item))
            Storage.shared.context.delete(item)
          }
        }
      }
      try? Storage.shared.context.save()
      if let newCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>()) {
        totalCount = newCount
      }
    }
  }
  
  // Limit image preview thumbnails to maxThumbnailCount (99), removing oldest ones asynchronously
  private func limitImageThumbnailsIfNeeded() {
    // Only process if we have more than maxThumbnailCount thumbnails
    guard itemsWithThumbnails.count > maxThumbnailCount else { return }
    
    // Process asynchronously to avoid blocking
    Task { @MainActor in
      // Sort by date (oldest first) and get items to cleanup
      let sortedThumbnails = itemsWithThumbnails.sorted { $0.value < $1.value }
      let toRemove = sortedThumbnails.prefix(itemsWithThumbnails.count - maxThumbnailCount)
      
      for (itemId, _) in toRemove {
        // Remove thumbnail from decorator if it exists
        if let decorator = loadedItems[itemId], decorator.thumbnailImage != nil {
          decorator.cleanupImages()
        }
        // Remove from tracking
        itemsWithThumbnails.removeValue(forKey: itemId)
      }
    }
  }
  
  // Track when a thumbnail is generated
  @MainActor
  func trackThumbnailGenerated(for itemId: UUID) {
    itemsWithThumbnails[itemId] = Date()
    limitImageThumbnailsIfNeeded()
  }
  
  // Remove tracking when item is deleted or cleaned up
  @MainActor
  func untrackThumbnail(for itemId: UUID) {
    itemsWithThumbnails.removeValue(forKey: itemId)
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    // Check for duplicates using database query
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      
      // Clean up and remove existing item
      if let existingDecorator = loadedItems.values.first(where: { $0.item == existingHistoryItem }) {
        cleanup(existingDecorator)
        loadedItems.removeValue(forKey: existingDecorator.id)
      } else {
        cleanup(HistoryItemDecorator(existingHistoryItem))
      }
      Storage.shared.context.delete(existingHistoryItem)
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Update total count
    totalCount = (try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())) ?? totalCount
    
    // Limit history size if needed (only for images/files)
    limitHistorySizeIfNeeded()

    sessionLog[Clipboard.shared.changeCount] = item

    let itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
    } else {
      itemDecorator = HistoryItemDecorator(item)
    }
    
    // Cache the new item
    loadedItems[itemDecorator.id] = itemDecorator
    
    // Update items list (reload from cache)
    items = Array(loadedItems.values).sorted { decorator1, decorator2 in
      sorter.compare(decorator1.item, decorator2.item)
    }

    updateUnpinnedShortcuts()
    AppState.shared.popup.needsResize = true
    
    // Limit image thumbnails if needed (asynchronously)
    limitImageThumbnailsIfNeeded()

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      // Clean up cached unpinned items
      let unpinnedIds = loadedItems.values.filter(\.isUnpinned).map(\.id)
      for id in unpinnedIds {
        if let item = loadedItems[id] {
          cleanup(item)
        }
        loadedItems.removeValue(forKey: id)
        itemsWithThumbnails.removeValue(forKey: id)
      }
      
      sessionLog.removeValues { $0.pin == nil }

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
      
      // Update items list
      items = Array(loadedItems.values).sorted { decorator1, decorator2 in
        sorter.compare(decorator1.item, decorator2.item)
      }
      totalCount = (try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())) ?? totalCount
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      // Clean up all cached items
      for item in loadedItems.values {
        cleanup(item)
      }
      loadedItems.removeAll()
      itemsWithThumbnails.removeAll()
      sessionLog.removeAll()
      items = []
      totalCount = 0

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    // cleanup() already calls cleanupImages() which untracks thumbnails
    withLogging("Removing history item") {
      Storage.shared.context.delete(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    loadedItems.removeValue(forKey: item.id)
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }
    totalCount = max(0, totalCount - 1)

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
    // cleanupImages() already calls untrackThumbnail, so no need to call it again
    // Clean up external files
    item.item.contents.forEach { content in
      if let filePath = content.filePath {
        Storage.shared.deleteCacheFile(at: filePath)
      }
    }
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()
    
    // Deduplicate pins after toggling
    deduplicatePins()

    // Re-sort items
    items = Array(loadedItems.values).sorted { decorator1, decorator2 in
      sorter.compare(decorator1.item, decorator2.item)
    }

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    // First check modified items
    if let modified = isModified(item) {
      return modified
    }
    
    // Get pure text from the new item
    let itemText = item.text ?? item.previewableText
    guard !itemText.isEmpty else {
      return nil
    }
    
    // Check database for items with the same pure text (ignore app sources)
    var descriptor = FetchDescriptor<HistoryItem>(
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1000 // Limit search to recent items
    
    if let recent = try? Storage.shared.context.fetch(descriptor) {
      if let duplicate = recent.first(where: { $0 != item && ($0.text ?? $0.previewableText) == itemText }) {
        return duplicate
      }
    }

    return nil
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  // This method is no longer used, replaced by updateItemsFromSearch
  // Keeping for compatibility
  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)
      loadedItems[item.id] = item
      return item
    }

    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(10) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
  
  @MainActor
  func deduplicatePins() {
    // Fetch all items with pins
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    
    guard let pinnedItems = try? Storage.shared.context.fetch(descriptor) else {
      return
    }
    
    // Group items by pin value
    var pinGroups: [String: [HistoryItem]] = [:]
    for item in pinnedItems {
      if let pin = item.pin {
        pinGroups[pin, default: []].append(item)
      }
    }
    
    // For each pin value with duplicates, keep only the most recent one
    var hasChanges = false
    for (pin, items) in pinGroups where items.count > 1 {
      // Items are already sorted by lastCopiedAt descending, so first is most recent
      let keepItem = items[0]
      
      // Remove pin from all other items
      for item in items.dropFirst() {
        item.pin = nil
        hasChanges = true
        
        // Update cache if item is loaded
        if let decorator = loadedItems.values.first(where: { $0.item == item }) {
          decorator.item.pin = nil
          decorator.shortcuts = [] // Clear shortcuts since pin is removed
        }
      }
    }
    
    // Save changes if any
    if hasChanges {
      try? Storage.shared.context.save()
      logger.info("Deduplicated duplicate pins")
      
      // Update items list and shortcuts after deduplication
      items = Array(loadedItems.values).sorted { decorator1, decorator2 in
        sorter.compare(decorator1.item, decorator2.item)
      }
      updateUnpinnedShortcuts()
    }
  }
}
