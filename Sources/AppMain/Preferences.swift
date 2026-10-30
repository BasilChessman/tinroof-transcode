import Foundation
import MediaCore

/// UserDefaults keys and typed accessors for application preferences.
enum Pref {
    static let fixDataBreaks = "fixDataBreaks"
    static let preserveGOPs = "preserveGOPs"
    static let convertOneAudioTrack = "convertOneAudioTrack"
    static let resample48k = "resample48k"
    static let mp2Bitrate = "mp2Bitrate"
    static let openPreviewWhenExporting = "openPreviewWhenExporting"
    static let autoResizePlayer = "autoResizePlayer"
    static let skipInterval = "skipInterval"
    static let defaultAudioMode = "defaultAudioMode"
    static let queueWhileBatchOpen = "queueWhileBatchOpen"
    static let resolveWebPages = "resolveWebPages"
    static let maxDisplayWidth = "maxDisplayWidth"

    static func register() {
        UserDefaults.standard.register(defaults: [
            fixDataBreaks: false,
            preserveGOPs: false,
            convertOneAudioTrack: false,
            resample48k: false,
            mp2Bitrate: 224,
            openPreviewWhenExporting: true,
            autoResizePlayer: true,
            skipInterval: 10.0,
            defaultAudioMode: 0,
            queueWhileBatchOpen: true,
            resolveWebPages: true,
            maxDisplayWidth: 1920,
        ])
    }

    static var d: UserDefaults { .standard }
    static var skip: Double { max(1, d.double(forKey: skipInterval)) }
}

extension RenderRequest {
    /// Applies the global conversion preferences.
    mutating func applyPreferences() {
        fixDataBreaks = fixDataBreaks || Pref.d.bool(forKey: Pref.fixDataBreaks)
        resampleTo48k = Pref.d.bool(forKey: Pref.resample48k)
        mp2BitrateKbps = Pref.d.integer(forKey: Pref.mp2Bitrate)
    }
}
