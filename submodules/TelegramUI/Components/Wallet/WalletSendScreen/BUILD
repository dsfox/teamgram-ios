load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

plist_fragment(
    name = "WalletSendAmountMetalSourcesBundleInfoPlist",
    extension = "plist",
    template = """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.WalletSendAmountMetalSources</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>WalletSendAmount</string>
    """,
)

apple_resource_bundle(
    name = "WalletSendAmountMetalSourcesBundle",
    infoplists = [":WalletSendAmountMetalSourcesBundleInfoPlist"],
    resources = glob(["Resources/*.metal"]),
)

swift_library(
    name = "WalletSendScreen",
    module_name = "WalletSendScreen",
    # ice9: no wallet here (#278); see Ice9NoPayments.
    srcs = ["//submodules/Ice9NoPayments:WalletSendScreenStub"],
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
        "//submodules/AttachmentUI",
        "//submodules/TelegramUI/Components/Premium/PremiumDiamondComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)
