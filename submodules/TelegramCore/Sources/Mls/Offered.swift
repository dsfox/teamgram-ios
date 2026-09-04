import Foundation

/// What this client offers, and what it does not offer yet.
///
/// One place, on purpose, and the twin of Offered.java on the other client -
/// the two have to hide the same things or a person moving between their own
/// phones finds a different messenger on each.
///
/// This is a fork of a client built against a server that answers everything,
/// running against a server that answers some of it. So there are buttons here
/// that would open an empty screen, or take an instruction and drop it
/// silently. A button that does nothing is worse than a button that is not
/// there: the first is a fault somebody carries around wondering about, the
/// second is simply a thing this messenger does not do yet.
///
/// Every switch below is false because something behind it is missing, and each
/// says what. Turning one back to true is the last step of restoring it, not
/// the first, and the epic (#83) holds the same list with what each one needs.
///
/// The rule: nothing is hidden anywhere in this client without a switch here.
/// A feature quietly removed and not written down is a feature nobody brings
/// back.
public enum Offered {

    /// Scheduling a message for later.
    ///
    /// Reading the scheduled list is a stub on the server and sending one has
    /// no handler at all, so the picker takes a date and nothing is ever sent
    /// or shown. Issue #26.
    public static let scheduledMessages = false

    /// Translating a message. No implementation anywhere. Issue #27.
    public static let translation = false

    /// The archive. Moving a chat there has no handler, so it slides away and
    /// comes back on the next sync. Issue #25.
    public static let archive = false

    /// Chat folders. Reading returns nothing, creating has no handler. #22.
    public static let folders = false

    /// Chat themes and name colours: both pickers would open empty. #23, #24.
    public static let chatThemes = false
    public static let nameColours = false

    /// Video chats. Nothing behind them. Issue #28.
    public static let videoChats = false

    /// Voice and video calls between people. Nothing places or receives one.
    /// Issue #14 - which is not #28 above, though the rows for both were once
    /// hidden by the same switch.
    public static let calls = false

    /// Stories. Nothing behind them, and a private messenger for a few people
    /// is not where they belong first.
    public static let stories = false

    /// Channels and public groups. This is an invitation-only messenger for
    /// conversations between people; broadcasting is a different thing.
    public static let channels = false

    /// An avatar built out of an emoji on a coloured background.
    ///
    /// There are no emoji to build it from: account.getDefaultProfilePhotoEmojis
    /// is an empty stub and no emoji pack can be installed (#20), so the picker
    /// opens empty with a search box that finds nothing. Comes back with the
    /// packs.
    public static let emojiAvatar = false

    /// Reactions. The server keeps none, so one appears for a moment on the
    /// phone that tapped it and is gone by the next sync.
    public static let reactions = false

    /// Sticker packs. messages.getAllStickers is answered with an empty list
    /// and installing one has no handler (#20), so every list of packs opens
    /// empty - MY STICKERS was a heading over a footer pointing at a bot that
    /// does not exist here. The emoji and animation settings on the same screen
    /// work and stay.
    public static let stickerPacks = false

    /// A cloud password - the second step asked for when signing in.
    ///
    /// account.getPassword is answered with "there is no password" and nothing
    /// handles setting one, so the screen would take a password, send it, and
    /// leave the account exactly as open as it was. Worse than absent: it reads
    /// as a lock that is on.
    public static let cloudPassword = false

    /// An address to receive login codes at. account.sendVerifyEmailCode is
    /// not implemented, so the screen would take an address and never confirm
    /// it. Android already hides the row unless the account has one.
    public static let loginEmail = false

    /// Gifts. The catalogue is answered with an empty list and nothing can be
    /// bought or sent, so a setting for who may send you one governs nothing.
    public static let gifts = false

    /// Bots and the mini apps that run inside them.
    ///
    /// Not a stub but an absence: the server has no bots service, and not one
    /// bots.* handler exists, so no account can be a bot and there is nothing
    /// for a search over apps to find. The client already knew - its .apps
    /// search returns an empty list without sending a request - and the tab
    /// stayed anyway. Issue #105.
    public static let bots = false

    /// A group's invite link: the row in the add-member picker, the "Invite
    /// Links" row of group info, the screen that sends the raw link to members
    /// the server refused, and the QR behind them.
    ///
    /// Not missing on the server - the link is minted and resolves - but it is
    /// not how anybody gets in here. An invitation is an SMS with a code bound
    /// to a number (#47), so the link is useless to somebody not on ice9; and
    /// the app drops it without a word for somebody signed out. Whoever is
    /// signed in did not need it: any member adds them from contacts. What it
    /// would do is admit anyone holding the hash. Issue #163.
    public static let groupInviteLinks = false

    // A round video in a conversation that encrypts used to be switched off
    // here: the one message uploaded while it was still being recorded, which
    // an encrypted upload cannot take. It is offered again since #80 - the
    // live upload is given up in ChatControllerMediaRecording where a secret
    // chat already gives it up, and the finished file goes up whole and
    // encrypted like any other video. Kept as a note rather than a switch,
    // so the next person looking for the row finds where it went.
}
