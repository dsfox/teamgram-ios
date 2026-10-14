load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

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
