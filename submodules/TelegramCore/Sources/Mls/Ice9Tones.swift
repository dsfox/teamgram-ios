import Foundation

/// The notification sounds the ice9 server hands out (#282): three short
/// tones embedded in its binary, listed by account.getSavedRingtones under
/// these fixed document ids. The server's copy of the list is
/// server/pkg/tones/tones.go; tests/test_both_clients_agree.py keeps the
/// two the same. Known here so the picker draws them under Alert Tones,
/// beside Default and None, with no delete swipe - the server refuses one.
public enum Ice9Tones {
    public static let ids: Set<Int64> = [
        0x1ce9_0000_0000_0001,
        0x1ce9_0000_0000_0002,
        0x1ce9_0000_0000_0003,
    ]
}
