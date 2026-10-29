#ifndef ICE9_PLAYOUT_PAUSE_H
#define ICE9_PLAYOUT_PAUSE_H

// What a private call does with the other side's words while iOS holds the
// call's sound - an alarm, Siri - and how fast it then plays them (#290).
//
// tgcalls stops the audio unit for an interruption while packets keep coming
// into the jitter buffer. Upstream's behaviour, kept when the person turns on
// "Catch up after a pause": on resume the buffer is seconds behind, and NetEq
// plays it accelerated - about twice as fast - until it is live again. People
// heard that as a fault. ice9's default: while the sound is held, the device
// keeps pulling decoded audio at the real rate and throws it away, so the call
// resumes live, at normal speed, and what was said meanwhile is lost.
//
// PlayoutStats measures the result where it can be seen: the RTP time of what
// is played against the wall clock, over one-second windows. 100 is real time;
// the accelerated catch-up reads 130 and more.

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <mutex>

namespace ice9 {

inline std::atomic<bool> &catchUpAfterPause() {
    static std::atomic<bool> value{false};
    return value;
}

class PlayoutStats {
public:
    // One frame went to the speaker: `elapsedMs` is its RTP time since the
    // stream began, `nowMs` the wall clock.
    void played(int64_t elapsedMs, int64_t nowMs) {
        if (elapsedMs < 0) {
            return;
        }
        std::lock_guard<std::mutex> lock(_mutex);
        // A gap in the pulls is the speaker stopped, not playout running fast.
        if (_lastWallMs < 0 || nowMs - _lastWallMs > 100 || elapsedMs < _windowElapsedMs) {
            _windowWallMs = nowMs;
            _windowElapsedMs = elapsedMs;
        } else if (nowMs - _windowWallMs >= 1000) {
            int speed = (int)((elapsedMs - _windowElapsedMs) * 100 / (nowMs - _windowWallMs));
            _maxSpeedPercent.store(std::max(_maxSpeedPercent.load(), speed));
            _windowWallMs = nowMs;
            _windowElapsedMs = elapsedMs;
        }
        _lastWallMs = nowMs;
    }

    void discarded(int ms) {
        _discardedMs.fetch_add(ms);
    }

    void reset() {
        std::lock_guard<std::mutex> lock(_mutex);
        _lastWallMs = -1;
        _maxSpeedPercent.store(0);
        _discardedMs.store(0);
    }

    int maxSpeedPercent() const {
        return _maxSpeedPercent.load();
    }

    int discardedMs() const {
        return _discardedMs.load();
    }

private:
    std::mutex _mutex;
    int64_t _lastWallMs = -1;
    int64_t _windowWallMs = 0;
    int64_t _windowElapsedMs = 0;
    std::atomic<int> _maxSpeedPercent{0};
    std::atomic<int> _discardedMs{0};
};

inline PlayoutStats &playoutStats() {
    static PlayoutStats stats;
    return stats;
}

// What the shared audio device did during one call (#293). A callee once
// heard nothing and was not heard, and the summary could not say whether the
// speaker ever asked for sound, whether the microphone gave frames, or how
// many calls' transports the device carried - so it counts them. Reset when
// the call's summary begins; `held` is the hold's state, not a count, so it
// survives the reset and says whether the call began with the sound held.
class DeviceCounters {
public:
    void speakerPulled(size_t transports) {
        _speakerPulls.fetch_add(1);
        if (transports == 0) {
            _pullsWithoutTransport.fetch_add(1);
        }
        int count = (int)transports;
        int seen = _transportsMax.load();
        while (count > seen && !_transportsMax.compare_exchange_weak(seen, count)) {
        }
    }

    void micFrame() {
        _micFrames.fetch_add(1);
    }

    void setHeld(bool held) {
        _held.store(held);
        if (held) {
            _holds.fetch_add(1);
        }
    }

    void holdEndedByActivation() {
        _holdsEndedByActivation.fetch_add(1);
    }

    void reset() {
        _heldAtStart.store(_held.load());
        _speakerPulls.store(0);
        _pullsWithoutTransport.store(0);
        _transportsMax.store(0);
        _micFrames.store(0);
        _holds.store(0);
        _holdsEndedByActivation.store(0);
    }

    int speakerPulls() const { return _speakerPulls.load(); }
    int pullsWithoutTransport() const { return _pullsWithoutTransport.load(); }
    int transportsMax() const { return _transportsMax.load(); }
    int micFrames() const { return _micFrames.load(); }
    int holds() const { return _holds.load(); }
    int holdsEndedByActivation() const { return _holdsEndedByActivation.load(); }
    bool heldAtStart() const { return _heldAtStart.load(); }
    bool held() const { return _held.load(); }

private:
    std::atomic<int> _speakerPulls{0};
    std::atomic<int> _pullsWithoutTransport{0};
    std::atomic<int> _transportsMax{0};
    std::atomic<int> _micFrames{0};
    std::atomic<int> _holds{0};
    std::atomic<int> _holdsEndedByActivation{0};
    std::atomic<bool> _held{false};
    std::atomic<bool> _heldAtStart{false};
};

inline DeviceCounters &deviceCounters() {
    static DeviceCounters counters;
    return counters;
}

}

#endif
