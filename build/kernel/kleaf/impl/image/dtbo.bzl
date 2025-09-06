# Copyright (C) 2022 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Build dtbo."""

load(":common_providers.bzl", "KernelBuildInfo", "KernelEnvAndOutputsInfo")
load(":debug.bzl", "debug")
load(":utils.bzl", "utils")
load("//build/kernel/kleaf:partition_size_setting.bzl", "PartitionSizeInfo")
load("//build/kernel/kleaf:props_flags.bzl", "PropsBuildSettingInfo")

visibility("//build/kernel/kleaf/...")

def _dtbo_impl(ctx):
    output = ctx.actions.declare_file("{}/dtbo.img".format(ctx.label.name))
    transitive_inputs = [target.files for target in ctx.attr.srcs]
    transitive_inputs.append(ctx.attr.kernel_build[KernelEnvAndOutputsInfo].inputs)
    tools = ctx.attr.kernel_build[KernelEnvAndOutputsInfo].tools
    command = ctx.attr.kernel_build[KernelEnvAndOutputsInfo].get_setup_script(
        data = ctx.attr.kernel_build[KernelEnvAndOutputsInfo].data,
        restore_out_dir_cmd = utils.get_check_sandbox_cmd(),
    )

    command += """
             # make dtbo
               mkdtimg create {output} ${{MKDTIMG_FLAGS}} {srcs}

	     # AVB footer (algo: NONE); add prop
             _dtbo_props=()
             if [ -n "${{FINGERPRINT:-}}" ]; then
               _dtbo_props+=( "--prop" "com.android.build.dtbo.fingerprint:${{FINGERPRINT}}" )
             fi

             image_size=$(stat -c%s "{output}" 2>/dev/null || \
                          stat -f%z "{output}" 2>/dev/null || \
                          wc -c < "{output}" 2>/dev/null) || image_size=0
             if [ "${{image_size}}" -gt 0 ]; then
               min_size=$((image_size + 1024 * 1024))
               dtbo_partition_size=$(( ( (min_size + 1024*1024 - 1) / (1024*1024) ) * 1024*1024 ))
             else
               dtbo_partition_size=$((8 * 1024 * 1024))
             fi

             if [[ -n "$AVB_KEY" ]]; then
               _dtbo_sign_args=( --algorithm "$AVB_ALGORITHM" --key "$AVB_KEY" )
             else
               _dtbo_sign_args=( --algorithm NONE )
             fi
             avbtool add_hash_footer \
               --image "{output}" \
               --partition_name dtbo \
               --partition_size "${{DTBO_PARTITION_SIZE:-${{dtbo_partition_size}}}}" \
               "${{_dtbo_sign_args[@]}}" \
               "${{_dtbo_props[@]}}"
    """.format(
        output = output.path,
        srcs = " ".join([f.path for f in ctx.files.srcs]),
    )

    env_for_action = {}
    if ctx.attr.dtbo_partition_size_setting:
        _sz = ctx.attr.dtbo_partition_size_setting[PartitionSizeInfo]
        if _sz and _sz.value:
            env_for_action["DTBO_PARTITION_SIZE"] = str(_sz.value)
    if ctx.attr.fingerprint_setting:
        _fp = ctx.attr.fingerprint_setting[PropsBuildSettingInfo]
        if _fp and _fp.value:
            env_for_action["FINGERPRINT"] = _fp.value
    if ctx.attr.avb_footer_key:
        env_for_action["AVB_KEY"] = ctx.file.avb_footer_key.path
        env_for_action["AVB_ALGORITHM"] = ctx.attr.avb_boot_algorithm

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = "Dtbo",
        inputs = depset(transitive = transitive_inputs),
        outputs = [output],
        tools = tools,
        progress_message = "Building dtbo {}".format(ctx.label),
        command = command,
        env = env_for_action,
    )
    return DefaultInfo(files = depset([output]))

dtbo = rule(
    implementation = _dtbo_impl,
    doc = "Build dtbo.",
    attrs = {
        "kernel_build": attr.label(
            mandatory = True,
            providers = [KernelEnvAndOutputsInfo, KernelBuildInfo],
        ),
        "srcs": attr.label_list(
            allow_files = True,
        ),
        "_debug_print_scripts": attr.label(
            default = "//build/kernel/kleaf:debug_print_scripts",
        ),
        "dtbo_partition_size_setting": attr.label(
            default = Label("//build/kernel/kleaf:dtbo_partition_size"),
            cfg = "host",
        ),
        "fingerprint_setting": attr.label(
            default = Label("//build/kernel/kleaf:fingerprint"),
            cfg = "host",
        ),
        "avb_footer_key": attr.label(
            allow_single_file = True,
            doc = "Private key for footer assembly (no key = algo NONE)",
        ),
    },
)
