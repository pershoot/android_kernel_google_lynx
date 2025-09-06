# kleaf/impl/avb_flags.bzl
load("@bazel_skylib//rules:common_settings.bzl", "string_flag", "bool_flag")

# Expose in kleaf/BUILD.bazel
def define_avb_flags():
    _vis = ["//build/kernel/kleaf:__subpackages__", "//common:__subpackages__"]

    # True: Bazel label for key (@avb_key_repo); False: plain string for key (default)
    bool_flag(
        name = "avb_key_use_label",
        build_setting_default = False,
        visibility = _vis,
    )

    # PEM abs. key path (disabled: empty)
    string_flag(
        name = "avb_boot_key",
        build_setting_default = "",
        visibility = _vis,
    )

    # Default algo. (override)
    string_flag(
        name = "avb_boot_algorithm",
        build_setting_default = "SHA256_RSA4096",
        values = [
            "SHA256_RSA2048", "SHA256_RSA4096", "SHA256_RSA8192",
            "SHA512_RSA2048", "SHA512_RSA4096", "SHA512_RSA8192",
        ],
        visibility = _vis,
    )

    # Partition name (boot)
    string_flag(
        name = "avb_boot_partition_name",
        build_setting_default = "boot",
        visibility = _vis,
    )

    # Partition size (bytes (empty: calculated)).
    string_flag(
        name = "avb_boot_partition_size",
        build_setting_default = "",
        visibility = _vis,
    )

    # Boot rollback index (string; "0" = not set)
    string_flag(
        name = "avb_boot_rollback_index",
        build_setting_default = "0",
        visibility = _vis,
    )
