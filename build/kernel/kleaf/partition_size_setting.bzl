# build/kernel/kleaf/partition_size_setting.bzl
PartitionSizeInfo = provider(fields = {
    "value": "The integer value (bytes) of the partition size build setting"
})

def _impl(ctx):
    return [PartitionSizeInfo(value = ctx.build_setting_value)]

_partition_size_setting_rule = rule(
    implementation = _impl,
    build_setting = config.int(flag = True),
    doc = "Build setting for partition size in bytes (integer).",
)

# Expose in kleaf/BUILD.bazel
def define_partition_size_setting(visibility = ["//visibility:public"]):
    _partition_size_setting_rule(
        name = "vendor_kernel_boot_partition_size",
        build_setting_default = 0,
        visibility = visibility,
    )

    _partition_size_setting_rule(
        name = "dtbo_partition_size",
        build_setting_default = 0,
        visibility = visibility,
    )

    _partition_size_setting_rule(
        name = "boot_partition_size",
        build_setting_default = 0,
        visibility = visibility,
    )
