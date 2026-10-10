
objc_library(
    name = "Stripe",
    enable_modules = True,
    module_name = "Stripe",
    # ice9: no card payment SDK in the app (#181). The target stays so its
    # dependents need no edit; it compiles nothing. Upstream's code is left in
    # Sources/ for the next carry.
    srcs = [],
    hdrs = [],
    includes = [
        "PublicHeaders",
    ],
    copts = [
        "-I{}/PublicHeaders/Stripe".format(package_name()),
    ],
    sdk_frameworks = [
        "Foundation",
        "UIKit",
        "AddressBook",
    ],
    weak_sdk_frameworks = [
        "PassKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
