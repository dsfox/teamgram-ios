load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "WalletScreen",
    module_name = "WalletScreen",
    # ice9: no wallet here (#278); see Ice9NoPayments.
    srcs = ["//submodules/Ice9NoPayments:WalletScreenStub"],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/AccountContext",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/WalletContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "WalletStickerPlacementTestsLib",
    testonly = True,
    srcs = ["Sources/WalletStickerPlacement.swift", "//submodules/TelegramUI/Components/Wallet/WalletGiftStickerMediaComponent:Sources/WalletGiftStickerCutout.swift", "Tests/WalletStickerPlacementTests.swift", "//submodules/TelegramUI/Components/Wallet/WalletCardComponent:Sources/WalletStickerAnimation.swift"],
    deps = ["//submodules/WalletContext"],
)
ios_test_runner(name = "WalletStickerPlacementTestRunner", device_type = "iPhone 17", os_version = "26.5")
ios_unit_test(
    name = "WalletStickerPlacementTests",
    minimum_os_version = "15.0",
    runner = ":WalletStickerPlacementTestRunner",
    deps = [":WalletStickerPlacementTestsLib"],
)
