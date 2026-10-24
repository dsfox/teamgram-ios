import Foundation
import TelegramCore
import SwiftSignalKit

public func effectiveDataSaving(for settings: VoiceCallSettings?, autodownloadSettings: AutodownloadSettings) -> VoiceCallDataSaving {
    if let settings = settings {
        if case .default = settings.dataSaving {
            switch (autodownloadSettings.mediumPreset.lessDataForPhoneCalls, autodownloadSettings.highPreset.lessDataForPhoneCalls) {
                case (true, true):
                    return .always
                case (true, false):
                    return .cellular
                default:
                    return .never
            }
        } else {
            return settings.dataSaving
        }
    } else {
        return .never
    }
}

public enum VoiceCallDataSaving: Int32 {
    case never
    case cellular
    case always
    case `default`
}

public struct VoiceCallSettings: Codable, Equatable {
    public var dataSaving: VoiceCallDataSaving
    public var enableSystemIntegration: Bool
    public var catchUpAfterPause: Bool // ice9: catch up after a pause is a setting, off by default (#290)
    
    public static var defaultSettings: VoiceCallSettings {
        return VoiceCallSettings(dataSaving: .default, enableSystemIntegration: true)
    }
    
    public init(dataSaving: VoiceCallDataSaving, enableSystemIntegration: Bool, catchUpAfterPause: Bool = false) {
        self.dataSaving = dataSaving
        self.enableSystemIntegration = enableSystemIntegration
        self.catchUpAfterPause = catchUpAfterPause // ice9: catch up after a pause is a setting, off by default (#290)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.dataSaving = VoiceCallDataSaving(rawValue: try container.decode(Int32.self, forKey: "ds")) ?? .default
        self.enableSystemIntegration = (try container.decode(Int32.self, forKey: "enableSystemIntegration")) != 0
        self.catchUpAfterPause = (try container.decodeIfPresent(Int32.self, forKey: "ice9CatchUp") ?? 0) != 0 // ice9: catch up after a pause is a setting, off by default (#290)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode(self.dataSaving.rawValue, forKey: "ds")
        try container.encode((self.enableSystemIntegration ? 1 : 0) as Int32, forKey: "enableSystemIntegration")
        try container.encode((self.catchUpAfterPause ? 1 : 0) as Int32, forKey: "ice9CatchUp") // ice9: catch up after a pause is a setting, off by default (#290)
    }
    
    public static func ==(lhs: VoiceCallSettings, rhs: VoiceCallSettings) -> Bool {
        if lhs.dataSaving != rhs.dataSaving {
            return false
        }
        if lhs.enableSystemIntegration != rhs.enableSystemIntegration {
            return false
        }
        if lhs.catchUpAfterPause != rhs.catchUpAfterPause { // ice9: catch up after a pause is a setting, off by default (#290)
            return false
        }
        return true
    }
}

public func updateVoiceCallSettingsSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (VoiceCallSettings) -> VoiceCallSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.voiceCallSettings, { entry in
            let currentSettings: VoiceCallSettings
            if let entry = entry?.get(VoiceCallSettings.self) {
                currentSettings = entry
            } else {
                currentSettings = VoiceCallSettings.defaultSettings
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}
