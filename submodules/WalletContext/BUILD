load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "WalletContext",
    module_name = "WalletContext",
    # ice9: no wallet here (#278); see Ice9NoPayments.
    srcs = ["//submodules/Ice9NoPayments:WalletContextStub"],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramUIPreferences",
        "//submodules/PasscodeCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "WalletCardStickersTestsLib",
    testonly = True,
    srcs = ["Tests/WalletCardStickersTests.swift"],
    deps = [":WalletContext", "//submodules/TelegramCore"],
)

ios_test_runner(
    name = "WalletCardStickersTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "WalletCardStickersTests",
    minimum_os_version = "15.0",
    runner = ":WalletCardStickersTestRunner",
    deps = [":WalletCardStickersTestsLib"],
)

swift_library(
    name = "WalletWidgetCallsTestsLib",
    testonly = True,
    srcs = ["Tests/WalletWidgetCallsTests.swift"],
    deps = [":WalletContext", "//submodules/TelegramCore", "//third-party/wallet-engine:WalletEngineFFI"],
)

ios_unit_test(
    name = "WalletWidgetCallsTests",
    minimum_os_version = "15.0",
    runner = ":WalletCardStickersTestRunner",
    deps = [":WalletWidgetCallsTestsLib"],
)
