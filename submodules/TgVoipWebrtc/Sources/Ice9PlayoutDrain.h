// Members of WrappedAudioDeviceModuleIOS, kept in a file of ours (#290).
// While iOS holds the call's sound the audio unit is stopped and nothing pulls
// the other side's words out of the jitter buffer. Unless the person chose to
// catch up, they are pulled here at the real rate and thrown away, so the call
// resumes live and at normal speed. See Ice9PlayoutPause.h.

public:
void ice9HoldPlayout(bool held) {
    if (held == _ice9Held) {
        return;
    }
    _ice9Held = held;
    _ice9DrainedUntilMs = rtc::TimeMillis();
    _ice9HeldSinceMs = _ice9DrainedUntilMs;
    RTC_LOG(LS_WARNING) << "ice9: call sound " << (held ? "held" : "back") << ", catch up " << ice9::catchUpAfterPause().load();
    if (held) {
        _ice9Safety = webrtc::PendingTaskSafetyFlag::Create();
        ice9DrainTick();
    } else if (_ice9Safety) {
        _ice9Safety->SetNotAlive();
        _ice9Safety = nullptr;
    }
}

private:
void ice9DrainTick() {
    if (!_ice9Held || !_ice9Safety) {
        return;
    }
    int64_t now = rtc::TimeMillis();
    // iOS does not always say an interruption ended: once the speaker pulls
    // again it is back, and pulling here too would take its audio away.
    if (_ice9LastRealPullMs > _ice9HeldSinceMs + 100) {
        RTC_LOG(LS_WARNING) << "ice9: the speaker pulls again, the hold is over";
        _ice9Held = false;
        _ice9Safety = nullptr;
        return;
    }
    if (ice9::catchUpAfterPause().load()) {
        _ice9DrainedUntilMs = now;
    } else {
        const size_t samplesPer10Ms = 480;
        if (_ice9DrainBuffer.size() < samplesPer10Ms) {
            _ice9DrainBuffer.resize(samplesPer10Ms);
        }
        _mutex.Lock();
        while (_ice9DrainedUntilMs + 10 <= now) {
            _ice9DrainedUntilMs += 10;
            if (_audioTransports.empty()) {
                continue;
            }
            size_t samplesOut = 0;
            int64_t elapsed = 0;
            int64_t ntp = 0;
            _audioTransports[_audioTransports.size() - 1].first->NeedMorePlayData(samplesPer10Ms, 2, 1, 48000, _ice9DrainBuffer.data(), samplesOut, &elapsed, &ntp);
            ice9::playoutStats().discarded(10);
        }
        _mutex.Unlock();
    }
    tgcalls::StaticThreads::getThreads()->getWorkerThread()->PostDelayedTask(webrtc::SafeTask(_ice9Safety, [this]() {
        ice9DrainTick();
    }), webrtc::TimeDelta::Millis(10));
}

bool _ice9Held = false;
int64_t _ice9HeldSinceMs = 0;
std::atomic<int64_t> _ice9LastRealPullMs{0};
int64_t _ice9DrainedUntilMs = 0;
std::vector<int16_t> _ice9DrainBuffer;
rtc::scoped_refptr<webrtc::PendingTaskSafetyFlag> _ice9Safety;

public:
