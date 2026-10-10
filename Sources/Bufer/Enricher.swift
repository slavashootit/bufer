import AppKit
import LinkPresentation
import Vision

/// Background extras for new items: text recognition on images and titles for links.
@MainActor
final class Enricher {
    private let store: Store
    private let onUpdate: () -> Void
    private let ocrQueue = DispatchQueue(label: "bufer.ocr", qos: .utility)
    /// LPMetadataProvider is single-use and must stay alive until it calls back.
    private var pendingProviders: [LPMetadataProvider] = []

    init(store: Store, onUpdate: @escaping () -> Void) {
        self.store = store
        self.onUpdate = onUpdate
    }

    func recognizeText(id: Int64, imageURL: URL) {
        guard Prefs.recognizeText else { return }
        ocrQueue.async { [weak self] in
            guard let text = Self.ocr(imageURL), !text.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.store.setOCR(id, text)
                self.onUpdate()
            }
        }
    }

    func fetchTitle(id: Int64, url: URL) {
        guard Prefs.fetchLinkTitles else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        pendingProviders.append(provider)
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            let title = metadata?.title
            Task { @MainActor in
                guard let self else { return }
                self.pendingProviders.removeAll { $0 === provider }
                if let title, !title.isEmpty {
                    self.store.setLinkTitle(id, title)
                    self.onUpdate()
                }
            }
        }
    }

    /// Vision text recognition; Ukrainian, English and Russian where the system supports them.
    nonisolated private static func ocr(_ url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let wanted = ["uk-UA", "en-US", "ru-RU"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let languages = wanted.filter { supported.contains($0) }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
