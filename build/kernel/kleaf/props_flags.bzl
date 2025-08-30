# build/kernel/kleaf/props_flags.bzl
PropsBuildSettingInfo = provider(fields = {"value": "The string value of the build setting"})

def _impl(ctx):
    return [PropsBuildSettingInfo(value = ctx.build_setting_value)]

_os_version_flag_rule = rule(
    implementation = _impl,
    build_setting = config.string(flag = True),
    doc = "OS version string for AVB prop",
)

_fingerprint_flag_rule = rule(
    implementation = _impl,
    build_setting = config.string(flag = True),
    doc = "Fingerprint string for AVB prop",
)

_spl_date_flag_rule = rule(
    implementation = _impl,
    build_setting = config.string(flag = True),
    doc = "SPL date (YYYY-MM-DD)",
)

# Expose in kleaf/BUILD.bazel
def define_props_flags(visibility = ["//visibility:public"]):
    _os_version_flag_rule(
        name = "os_version",
        build_setting_default = "",
        visibility = visibility,
    )
    _fingerprint_flag_rule(
        name = "fingerprint",
        build_setting_default = "",
        visibility = visibility,
    )
    _spl_date_flag_rule(
        name = "spl_date",
        build_setting_default = "",
        visibility = visibility,
    )
