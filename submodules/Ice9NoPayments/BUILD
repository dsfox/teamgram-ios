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
