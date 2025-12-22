import SwiftUI
import Defaults
import Settings

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size
  @State private var sizeText: String = ""
  
  private let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSize = 3
    return formatter
  }()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(
        bottomDivider: true,
        label: { Text("Save", tableName: "StorageSettings") }
      ) {
        Toggle(
          isOn: $viewModel.saveFiles,
          label: { Text("Files", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveImages,
          label: { Text("Images", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveText,
          label: { Text("Text", tableName: "StorageSettings") }
        )
        Text("SaveDescription", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)
      }

      Settings.Section(label: { Text("Size", tableName: "StorageSettings") }) {
        HStack {
          TextField("", text: $sizeText)
            .frame(width: 120)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
            .onChange(of: sizeText) { oldValue, newValue in
              // Remove commas and other non-numeric characters, keep only digits
              let cleaned = newValue.replacingOccurrences(of: ",", with: "").filter { $0.isNumber }
              
              // If the cleaned value is different, update the text field
              if cleaned != newValue.replacingOccurrences(of: ",", with: "") {
                // Parse the cleaned value
                if let number = Int(cleaned), !cleaned.isEmpty {
                  let clampedValue = max(1, min(1_000_000, number))
                  size = clampedValue
                  // Format with commas
                  if let formatted = numberFormatter.string(from: NSNumber(value: clampedValue)) {
                    sizeText = formatted
                  } else {
                    sizeText = String(clampedValue)
                  }
                } else if cleaned.isEmpty {
                  sizeText = ""
                }
                return
              }
              
              // Parse the value and update size
              if let number = Int(cleaned), !cleaned.isEmpty {
                let clampedValue = max(1, min(1_000_000, number))
                size = clampedValue
                // Format with commas if the number changed
                if clampedValue != number {
                  if let formatted = numberFormatter.string(from: NSNumber(value: clampedValue)) {
                    sizeText = formatted
                  } else {
                    sizeText = String(clampedValue)
                  }
                } else if !newValue.contains(",") {
                  // If user typed a number without commas, format it
                  if let formatted = numberFormatter.string(from: NSNumber(value: clampedValue)) {
                    sizeText = formatted
                  }
                }
              } else if cleaned.isEmpty {
                // Allow empty text while typing
              }
            }
            .onSubmit {
              // When user presses enter, ensure we have a valid formatted value
              let cleaned = sizeText.replacingOccurrences(of: ",", with: "")
              if cleaned.isEmpty || Int(cleaned) == nil {
                if let formatted = numberFormatter.string(from: NSNumber(value: size)) {
                  sizeText = formatted
                } else {
                  sizeText = String(size)
                }
              } else {
                // Format the current value
                if let number = Int(cleaned), let formatted = numberFormatter.string(from: NSNumber(value: number)) {
                  sizeText = formatted
                }
              }
            }
            .onChange(of: size) { oldValue, newValue in
              // Update text when size changes externally (e.g., from stepper)
              let cleaned = sizeText.replacingOccurrences(of: ",", with: "")
              if Int(cleaned) != newValue {
                if let formatted = numberFormatter.string(from: NSNumber(value: newValue)) {
                  sizeText = formatted
                } else {
                  sizeText = String(newValue)
                }
              }
            }
            .onAppear {
              if let formatted = numberFormatter.string(from: NSNumber(value: size)) {
                sizeText = formatted
              } else {
                sizeText = String(size)
              }
            }
          Stepper("", value: $size, in: 1...1_000_000)
            .labelsHidden()
          Text("items")
            .controlSize(.small)
            .foregroundStyle(.gray)
          Text(storageSize)
            .controlSize(.small)
            .foregroundStyle(.gray)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
            .onAppear {
              storageSize = Storage.shared.size
            }
        }
      }

      Settings.Section(label: { Text("SortBy", tableName: "StorageSettings") }) {
        Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 160, alignment: .leading)
        .help(Text("SortByTooltip", tableName: "StorageSettings"))
      }
    }
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
