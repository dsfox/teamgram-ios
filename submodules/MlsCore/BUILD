load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MlsCore",
    module_name = "MlsCore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/mls:mls",
    ],
    visibility = [
        "//visibility:public",
    ],
)
