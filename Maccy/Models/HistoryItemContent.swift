import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  var value: Data?
  var filePath: String? // Path to external file for images/files

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil, filePath: String? = nil) {
    self.type = type
    self.value = value
    self.filePath = filePath
  }
}
