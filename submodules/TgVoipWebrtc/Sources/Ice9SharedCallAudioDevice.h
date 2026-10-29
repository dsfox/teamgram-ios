// Methods of SharedCallAudioDevice, kept in a file of ours (#290). See
// Ice9PlayoutPause.h for what they do and why.

+ (void)ice9SetCatchUpAfterPause:(bool)catchUp {
    ice9::catchUpAfterPause().store(catchUp);
}

+ (int)ice9PlayoutMaxSpeedPercent {
    return ice9::playoutStats().maxSpeedPercent();
}

+ (int)ice9PlayoutDiscardedMs {
    return ice9::playoutStats().discardedMs();
}

+ (void)ice9ResetPlayoutStats {
    ice9::playoutStats().reset();
}

- (void)ice9Interruption:(NSNotification *)notification {
    NSNumber *typeNumber = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    bool held = typeNumber != nil && (AVAudioSessionInterruptionType)typeNumber.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan;
    _audioDeviceModule->perform([held](tgcalls::SharedAudioDeviceModule *audioDeviceModule) {
        ((WrappedAudioDeviceModuleIOS *)audioDeviceModule->audioDeviceModule().get())->ice9HoldPlayout(held);
    });
}

// The session handed over from outside ends a hold (#293). Posted to the
// device's thread like an interruption, so the two arrive in order.
- (void)ice9ActivatedFromOutside {
    _audioDeviceModule->perform([](tgcalls::SharedAudioDeviceModule *audioDeviceModule) {
        ((WrappedAudioDeviceModuleIOS *)audioDeviceModule->audioDeviceModule().get())->ice9ActivatedFromOutside();
    });
}

// What the device did during this call, for its summary (#293).
+ (void)ice9ResetDeviceCounters {
    ice9::deviceCounters().reset();
}

+ (NSDictionary<NSString *, NSNumber *> * _Nonnull)ice9DeviceCounters {
    ice9::DeviceCounters &c = ice9::deviceCounters();
    return @{
        @"speaker_pulls": @(c.speakerPulls()),
        @"pulls_without_transport": @(c.pullsWithoutTransport()),
        @"transports_max": @(c.transportsMax()),
        @"mic_frames": @(c.micFrames()),
        @"holds": @(c.holds()),
        @"holds_ended_by_activation": @(c.holdsEndedByActivation()),
        @"held_at_start": @(c.heldAtStart()),
        @"held_at_end": @(c.held())
    };
}
