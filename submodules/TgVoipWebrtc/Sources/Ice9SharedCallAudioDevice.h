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
