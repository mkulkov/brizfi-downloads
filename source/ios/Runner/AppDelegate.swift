import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var readerPreferencesChannel: FlutterMethodChannel?
  private var importChannel: FlutterMethodChannel?
  private var importResult: FlutterResult?
  private let importQueue = DispatchQueue(label: "ru.mkulkov.brizfi.import")
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BrizfiBookImporter") else { return }
    let preferencesChannel = FlutterMethodChannel(
      name: "ru.mkulkov.brizfi/reader_preferences", binaryMessenger: registrar.messenger())
    readerPreferencesChannel = preferencesChannel
    preferencesChannel.setMethodCallHandler { call, result in
      let brands = Set(["kindle", "nook", "kobo", "pocketbook", "onyx", "other"])
      func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 160 && key.utf8.allSatisfy {
          (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || [45, 58, 95].contains($0)
        }
      }
      let defaults = UserDefaults.standard
      var saved = (defaults.dictionary(forKey: "reader_preferences") ?? [:])
        .filter { validKey($0.key) && ($0.value as? String).map { brands.contains($0) } == true }
      if saved.count > 128 { saved = Dictionary(uniqueKeysWithValues: saved.prefix(128).map { ($0.key, $0.value) }) }
      switch call.method {
      case "read": result(saved)
      case "write":
        guard let args = call.arguments as? [String: Any], let key = args["key"] as? String,
          let brand = args["brand"] as? String, validKey(key), brands.contains(brand) else {
          result(FlutterError(code: "invalid_arguments", message: "Invalid reader preference", details: nil)); return
        }
        guard saved[key] != nil || saved.count < 128 else {
          result(FlutterError(code: "preferences_full", message: "Reader preference limit reached", details: nil)); return
        }
        saved[key] = brand
        defaults.set(saved, forKey: "reader_preferences")
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(
      name: "ru.mkulkov.brizfi/import", binaryMessenger: registrar.messenger())
    importChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickAzw3" else { result(FlutterMethodNotImplemented); return }
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Importer unavailable.", details: nil))
        return
      }
      guard self.importResult == nil else {
        result(FlutterError(code: "busy", message: "An import is already pending.", details: nil))
        return
      }
      let controller = self.window?.rootViewController
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
      guard let controller, controller.presentedViewController == nil else {
        result(FlutterError(code: "unavailable", message: "File picker unavailable.", details: nil))
        return
      }
      self.importResult = result
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
      picker.allowsMultipleSelection = false
      picker.delegate = self
      controller.present(picker, animated: true)
    }
    importQueue.async { Self.cleanExpiredCopies() }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    importResult?(nil)
    importResult = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let source = urls.first, importResult != nil else { return }
    importQueue.async { [weak self] in
      let outcome: Result<URL, Error>
      do { outcome = .success(try Self.copyBook(source)) }
      catch { outcome = .failure(error) }
      DispatchQueue.main.async { [weak self] in
        guard let self, let result = self.importResult else {
          if case .success(let target) = outcome {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
          }
          return
        }
        self.importResult = nil
        switch outcome {
        case .success(let target): result(target.path)
        case .failure(let error):
          result(FlutterError(code: (error as? ImportFailure)?.code ?? "import_failed",
            message: "The selected book could not be imported.", details: nil))
        }
      }
    }
  }

  private struct ImportFailure: Error { let code: String }

  private static var importRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("brizfi_imports", isDirectory: true)
  }

  private static func cleanExpiredCopies() {
    let expiry = Date().addingTimeInterval(-24 * 60 * 60)
    let manager = FileManager.default
    guard let copies = try? manager.contentsOfDirectory(at: importRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { return }
    for copy in copies {
      guard let values = try? copy.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
        values.isDirectory == true, let modified = values.contentModificationDate,
        modified < expiry else { continue }
      try? manager.removeItem(at: copy)
    }
  }

  private static func copyBook(_ source: URL) throws -> URL {
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    guard source.pathExtension.lowercased() == "azw3" else {
      throw ImportFailure(code: "unsupported_format")
    }
    let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
    let name = source.lastPathComponent.components(separatedBy: unsafe).joined(separator: "_")
    let safeName = String(name.dropLast(5).prefix(120)) + ".azw3"
    let directory = importRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = directory.appendingPathComponent(safeName)
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      guard manager.createFile(atPath: target.path, contents: nil) else {
        throw ImportFailure(code: "import_failed")
      }
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: target)
      defer { try? output.close() }
      var total = 0
      while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
        total += data.count
        guard total <= 32 * 1024 * 1024 else { throw ImportFailure(code: "too_large") }
        try output.write(contentsOf: data)
      }
      guard total > 0 else { throw ImportFailure(code: "invalid_file") }
      return target
    } catch {
      try? manager.removeItem(at: directory)
      throw error
    }
  }
}
