load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "InAppPurchaseManager",
    module_name = "InAppPurchaseManager",
    # ice9: nothing here sells or takes payment (#181); see Ice9NoPayments.
    srcs = ["//submodules/Ice9NoPayments:InAppPurchaseManagerStub"],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/PersistentStringHash:PersistentStringHash",
    ],
    visibility = [
        "//visibility:public",
    ],
)
