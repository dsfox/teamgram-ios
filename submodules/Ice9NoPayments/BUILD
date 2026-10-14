# ice9 sells nothing and takes no payment, in any build (#181). Apple refused
# 12.9.2 because the binary still carried Telegram's purchase, Apple Pay and card
# code, so those modules compile these files instead of upstream's: each module
# keeps its label and its name, its BUILD names the file here, and upstream's
# Sources/ stay in the tree untouched for the next carry. A caller that starts
# using something these files do not provide fails to compile, loudly.
#
# Held by tools/ipa_gate.py (the IPA and the sources) and the pins in
# tests/test_carried_fixes.py.

filegroup(
    name = "InAppPurchaseManagerStub",
    srcs = ["InAppPurchaseManager.swift"],
    visibility = ["//submodules/InAppPurchaseManager:__pkg__"],
)

filegroup(
    name = "BotPaymentsUIStub",
    srcs = ["BotPaymentsUI.swift"],
    visibility = ["//submodules/BotPaymentsUI:__pkg__"],
)

filegroup(
    name = "PaymentMethodUIStub",
    srcs = ["PaymentMethodUI.swift"],
    visibility = ["//submodules/PaymentMethodUI:__pkg__"],
)

# The TON wallet of Telegram 13.0 is payment functionality too (#278): its
# context and every screen the app imports compile these files instead.

filegroup(
    name = "WalletContextStub",
    srcs = ["WalletContext.swift"],
    visibility = ["//submodules/WalletContext:__pkg__"],
)

filegroup(
    name = "WalletScreenStub",
    srcs = ["WalletScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletScreen:__pkg__"],
)

filegroup(
    name = "WalletReceiveScreenStub",
    srcs = ["WalletReceiveScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletReceiveScreen:__pkg__"],
)

filegroup(
    name = "WalletImportScreenStub",
    srcs = ["WalletImportScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletImportScreen:__pkg__"],
)

filegroup(
    name = "WalletSettingsScreenStub",
    srcs = ["WalletSettingsScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletSettingsScreen:__pkg__"],
)

filegroup(
    name = "WalletAppsScreenStub",
    srcs = ["WalletAppsScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletAppsScreen:__pkg__"],
)

filegroup(
    name = "WalletWordsScreenStub",
    srcs = ["WalletWordsScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletWordsScreen:__pkg__"],
)

filegroup(
    name = "WalletInfoScreenStub",
    srcs = ["WalletInfoScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletInfoScreen:__pkg__"],
)

filegroup(
    name = "WalletTransactionScreenStub",
    srcs = ["WalletTransactionScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletTransactionScreen:__pkg__"],
)

filegroup(
    name = "WalletCollectibleScreenStub",
    srcs = ["WalletCollectibleScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletCollectibleScreen:__pkg__"],
)

filegroup(
    name = "WalletConnectScreenStub",
    srcs = ["WalletConnectScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletConnectScreen:__pkg__"],
)

filegroup(
    name = "WalletSendScreenStub",
    srcs = ["WalletSendScreen.swift"],
    visibility = ["//submodules/TelegramUI/Components/Wallet/WalletSendScreen:__pkg__"],
)

# The Rust MTProto engine of Telegram 13.0 carries Telegram's hosts in its
# strings; the factory the app makes declines, and MtProtoKit runs (#278).
filegroup(
    name = "MTProtoRustEngineStub",
    srcs = ["MTProtoRustEngine.swift"],
    visibility = ["//submodules/MTProtoRustEngine:__pkg__"],
)
