# The MLS core, built outside this repository.
#
# The library itself lives in the 2bytes repository under crypto/mls, is written
# once and used by both clients; crypto/build.sh compiles it for every target
# and copies the results here. That is why nothing is built in this file: the
# alternative is a Rust toolchain inside Bazel, which buys nothing when the same
# artifact has to be produced for Android anyway.
#
# Run crypto/build.sh before building the app. Without it these files are
# missing and Bazel says so plainly, which is better than a build that quietly
# links yesterday's crypto.

licenses(["notice"])

cc_library(
    name = "mls_lib",
    srcs = select({
        "//build-system:ios_sim_arm64": ["lib/libmls-sim.a"],
        "//conditions:default": ["lib/libmls-device.a"],
    }),
)

objc_library(
    name = "mls",
    module_name = "mls",
    enable_modules = True,
    hdrs = ["include/mls.h"],
    includes = ["include"],
    deps = [":mls_lib"],
    visibility = ["//visibility:public"],
)
