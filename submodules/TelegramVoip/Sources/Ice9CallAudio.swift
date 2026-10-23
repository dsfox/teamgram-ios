import Foundation
import AVFoundation
import UIKit
import TelegramCore

/// What a private call did with sound, on this phone (#288).
///
/// A callee woken by a call once heard the caller and was not heard, and
/// nothing on either side said whether the microphone gave silence, the audio
/// session never came up, or the sound was lost on the way (#190 was the same
/// on an iPhone). This keeps, per call: how long the app had been running when
/// the call began, when CallKit handed over the audio session, when the call
/// connected, the other side's level as the engine reported it, and what the
/// audio session said about the microphone - permission, input route,
/// interruptions and route changes. It goes into the app log and, under
/// "ice9", into the stats log sent after the call (phone.saveCallDebug), where
/// the server writes it beside the route.
///
/// The engine reports only the other side's level on iOS; whether this phone
/// sent sound is read from the stats log's send bitrate and from the other
/// phone's summary.
final class Ice9CallAudio {
    // tgcalls reports levels from 0 to 1; speech sits well above this.
    private static let heard: Float = 0.01
    private static let reportEvery: Double = 5.0

    private let lock = NSLock()
    private let callId: Int64
    private let incoming: Bool
    private let createdAt = CFAbsoluteTimeGetCurrent()
    private let processAgeMs: Int64
    private var sessionActiveAt: Double = 0
    private var establishedAt: Double = 0
    private var samples = 0
    private var peerMax: Float = 0
    private var peerHeard = 0
    private var peerFirstMs: Int64 = -1
    private var muted = false
    private var interruptions = 0
    private var routeChanges = 0
    private var inputPortsAtConnect = "unknown"
    private var lastReport: Double = 0
    private var observers: [NSObjectProtocol] = []

    init(callId: Int64, isOutgoing: Bool) {
        self.callId = callId
        self.incoming = !isOutgoing
        self.processAgeMs = Ice9CallAudio.processAgeMs()
        Logger.shared.log("Ice9CallAudio", "call \(callId) \(isOutgoing ? "outgoing" : "incoming"), process up \(self.processAgeMs) ms, \(Ice9CallAudio.sessionLine())")

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            self?.count { $0.interruptions += 1 }
            Logger.shared.log("Ice9CallAudio", "audio session interrupted: \(type == .began ? "began" : "ended")")
        })
        self.observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            self?.count { $0.routeChanges += 1 }
            Logger.shared.log("Ice9CallAudio", "audio route changed, reason \(reason), \(Ice9CallAudio.sessionLine())")
        })
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// CallKit handed the audio session over; the engine starts from here.
    func audioSessionActivated() {
        let ms = self.count { audio -> Int64 in
            if audio.sessionActiveAt == 0 {
                audio.sessionActiveAt = CFAbsoluteTimeGetCurrent()
            }
            return Int64((audio.sessionActiveAt - audio.createdAt) * 1000.0)
        }
        Logger.shared.log("Ice9CallAudio", "audio session active \(ms) ms after the call began, \(Ice9CallAudio.sessionLine())")
    }

    /// The call connected: from here a silent line is a fault.
    func established() {
        let ports = Ice9CallAudio.inputPorts()
        self.count { audio in
            if audio.establishedAt == 0 {
                audio.establishedAt = CFAbsoluteTimeGetCurrent()
                audio.inputPortsAtConnect = ports
            }
        }
        Logger.shared.log("Ice9CallAudio", "established, \(Ice9CallAudio.sessionLine())")
    }

    func setMuted(_ value: Bool) {
        self.count { $0.muted = value }
    }

    /// One level report from the engine: the other side.
    func peerLevel(_ level: Float) {
        let report: String? = self.count { audio in
            audio.samples += 1
            let now = CFAbsoluteTimeGetCurrent()
            audio.peerMax = max(audio.peerMax, level)
            if level > Ice9CallAudio.heard {
                audio.peerHeard += 1
                if audio.peerFirstMs < 0 {
                    audio.peerFirstMs = audio.establishedAt != 0 ? Int64((now - audio.establishedAt) * 1000.0) : -1
                }
            }
            if now - audio.lastReport >= Ice9CallAudio.reportEvery {
                audio.lastReport = now
                return audio.summaryLine()
            }
            return nil
        }
        if let report {
            Logger.shared.log("Ice9CallAudio", report)
        }
    }

    /// The stats log the phone sends, with this call's summary under "ice9".
    func into(_ statsLog: String) -> String {
        let session = Ice9CallAudio.sessionValues()
        let (summary, line): ([String: Any], String) = self.count { audio in
            var o: [String: Any] = [
                "build": Ice9CallAudio.build(),
                "device": Ice9CallAudio.deviceModel(),
                "sdk": "iOS " + UIDevice.current.systemVersion,
                "incoming": audio.incoming,
                "process_ms": audio.processAgeMs,
                "audio_session_ms": audio.sessionActiveAt != 0 ? Int64((audio.sessionActiveAt - audio.createdAt) * 1000.0) : -1,
                "session_to_connect_ms": audio.sessionActiveAt != 0 && audio.establishedAt != 0 ? Int64((audio.establishedAt - audio.sessionActiveAt) * 1000.0) : -1,
                "input_ports": audio.inputPortsAtConnect,
                "interruptions": audio.interruptions,
                "route_changes": audio.routeChanges,
                "muted": audio.muted,
                "samples": audio.samples,
                "peer_max": Double(audio.peerMax),
                "peer_heard": audio.peerHeard,
                "peer_first_ms": audio.peerFirstMs
            ]
            for (key, value) in session {
                o[key] = value
            }
            return (o, audio.summaryLine())
        }
        Logger.shared.log("Ice9CallAudio", "ended, \(line)")
        var log: [String: Any] = [:]
        if let data = statsLog.data(using: .utf8), let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            log = parsed
        } else if !statsLog.isEmpty {
            return statsLog
        }
        log["ice9"] = summary
        guard let data = try? JSONSerialization.data(withJSONObject: log), let result = String(data: data, encoding: .utf8) else {
            return statsLog
        }
        return result
    }

    private func summaryLine() -> String {
        return "call \(self.callId) samples=\(self.samples) peer max=\(self.peerMax) heard=\(self.peerHeard) first=\(self.peerFirstMs)ms, muted=\(self.muted) interruptions=\(self.interruptions) routeChanges=\(self.routeChanges)"
    }

    @discardableResult
    private func count<T>(_ f: (Ice9CallAudio) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return f(self)
    }

    private static func sessionValues() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let permission: String
        switch session.recordPermission {
        case .granted:
            permission = "granted"
        case .denied:
            permission = "denied"
        case .undetermined:
            permission = "undetermined"
        @unknown default:
            permission = "unknown"
        }
        return [
            "mic_granted": permission,
            "input_available": session.isInputAvailable,
            "category": session.category.rawValue,
            "mode": session.mode.rawValue
        ]
    }

    private static func sessionLine() -> String {
        let values = sessionValues()
        return "mic=\(values["mic_granted"] ?? "") inputAvailable=\(values["input_available"] ?? "") inputs=\(inputPorts()) category=\(values["category"] ?? "") mode=\(values["mode"] ?? "")"
    }

    private static func inputPorts() -> String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        if inputs.isEmpty {
            return "none"
        }
        return inputs.map { $0.portType.rawValue }.joined(separator: ",")
    }

    private static func build() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return "Apple " + machine
    }

    private static func processAgeMs() -> Int64 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000.0
        return Int64((Date().timeIntervalSince1970 - started) * 1000.0)
    }
}
