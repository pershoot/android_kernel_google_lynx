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

"""Build GKI artifacts, including GKI boot images."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":common_providers.bzl", "KernelBuildUnameInfo")
load(":constants.bzl", "GKI_ARTIFACTS_AARCH64_OUTS")
load(":hermetic_toolchain.bzl", "hermetic_toolchain")
load(":utils.bzl", "utils")
load("//build/kernel/kleaf:partition_size_setting.bzl", "PartitionSizeInfo")
load("//build/kernel/kleaf:props_flags.bzl", "PropsBuildSettingInfo")

def _gki_artifacts_impl(ctx):
    hermetic_tools = hermetic_toolchain.get(ctx)
    inputs = [
        ctx.file.mkbootimg,
        ctx.file._testkey,
    ]
    tools = [
        ctx.file._build_utils_sh,
    ]
    transitive_tools = [hermetic_tools.deps]

    kernel_release = ctx.attr.kernel_build[KernelBuildUnameInfo].kernel_release
    inputs.append(kernel_release)

    outs = []
    boot_lz4 = None
    boot_gz = None

    tarball = ctx.actions.declare_file("{}/boot-img.tar.gz".format(ctx.label.name))
    outs.append(tarball)
    gki_info = ctx.actions.declare_file("{}/gki-info.txt".format(ctx.label.name))
    outs.append(gki_info)

    size_cmd = ""
    images = []
    for image in ctx.files.kernel_build:
        if image.basename in ("Image", "bzImage"):
            outs.append(ctx.actions.declare_file("{}/boot.img".format(ctx.label.name)))
            size_key = ""
            var_name = ""
        elif image.basename.startswith("Image."):
            compression = image.basename.removeprefix("Image.")
            size_key = compression
            var_name = "_" + compression.upper()
            boot_image = ctx.actions.declare_file("{}/boot-{}.img".format(ctx.label.name, compression))
            if compression == "lz4":
                boot_lz4 = boot_image
            elif compression == "gz":
                boot_gz = boot_image
            outs.append(boot_image)
        else:
            # Not an image
            continue

        images.append(image)
        size = ctx.attr.boot_img_sizes.get(size_key)
        if not size:
            fail("""{}: Missing key "{}" in boot_img_sizes for image {}.""".format(ctx.label, size_key, image.basename))
        size_cmd += """
            export BUILD_GKI_BOOT_IMG{var_name}_SIZE={size}
        """.format(var_name = var_name, size = size)

    # b/283225390: boot images with --gcov may overflow the boot image size
    #   check when adding AVB hash footer.
    skip_avb_cmd = ""
    if ctx.attr._gcov[BuildSettingInfo].value:
        skip_avb_cmd = """
            export BUILD_GKI_BOOT_SKIP_AVB=1
        """

    inputs += images

    # All declare_file's above are "<name>/<filename>" without subdirectories,
    # so using outs[0] is good enough.
    dist_dir = outs[0].dirname
    out_dir = paths.join(utils.intermediates_dir(ctx), "out_dir")

    # AVB inject (label-mode preferred; string path fallback)
    avb_env_cmd = ""
    use_label = ctx.attr._avb_key_use_label[BuildSettingInfo].value
    key = ctx.attr._avb_boot_key[BuildSettingInfo].value
    boot_partition_size_value = 0
    if ctx.attr.boot_partition_size_setting:
        _ps = ctx.attr.boot_partition_size_setting[PartitionSizeInfo]
        if _ps and _ps.value:
            boot_partition_size_value = int(_ps.value)
    if ctx.attr._avb_boot_partition_size:
        _bs = ctx.attr._avb_boot_partition_size[BuildSettingInfo]
        if _bs and _bs.value:
            boot_partition_size_value = int(_bs.value)
    if use_label:
        # Declared file as input (made available in the sandbox)
        key_path = ctx.file._avb_boot_key_file.path
        algo = ctx.attr._avb_boot_algorithm[BuildSettingInfo].value or "SHA256_RSA4096"
        pname = ctx.attr._avb_boot_partition_name[BuildSettingInfo].value or "boot"
        avb_env_cmd = """
export AVB_BOOT_KEY={key}
export AVB_BOOT_ALGORITHM={algo}
export AVB_BOOT_PARTITION_NAME={pname}
""".format(
            key = shell.quote(key_path),
            algo = shell.quote(algo),
            pname = shell.quote(pname),
        )
        if boot_partition_size_value:
            avb_env_cmd += "export AVB_BOOT_PARTITION_SIZE={psize}\n".format(
                psize = shell.quote(str(boot_partition_size_value)),
            )
    elif key:
        algo = ctx.attr._avb_boot_algorithm[BuildSettingInfo].value or "SHA256_RSA4096"
        pname = ctx.attr._avb_boot_partition_name[BuildSettingInfo].value or "boot"
        avb_env_cmd = """
export AVB_BOOT_KEY={key}
export AVB_BOOT_ALGORITHM={algo}
export AVB_BOOT_PARTITION_NAME={pname}
""".format(
            key = shell.quote(key),
            algo = shell.quote(algo),
            pname = shell.quote(pname),
        )
        if boot_partition_size_value:
            avb_env_cmd += "export AVB_BOOT_PARTITION_SIZE={psize}\n".format(
                psize = shell.quote(str(boot_partition_size_value)),
            )

    command = hermetic_tools.setup + """
        source {build_utils_sh}
        cp -pl -t {dist_dir} {images}
        mkdir -p {out_dir}/include/config
        cp -pl {kernel_release} {out_dir}/include/config/kernel.release
        export GKI_KERNEL_CMDLINE={quoted_gki_kernel_cmdline}
        export ARCH={quoted_arch}
        export DIST_DIR=$(readlink -e {dist_dir})
        export OUT_DIR=$(readlink -e {out_dir})
        export MKBOOTIMG_PATH={mkbootimg}
        export KLEAF_INTERNAL_GKI_BOOT_IMG_CERTIFICATION_KEY={testkey}
        {size_cmd}
        {avb_env_cmd}
        {skip_avb_cmd}
        build_gki_artifacts
        # Finalize AVB signing (last write is signed footer)
        if [ -n "${{AVB_BOOT_KEY:-}}" ]; then
          sign_one() {{
            local img="$1"
            [ -f "$img" ] || return 0
            # Boot only for the interim; ignore overrides
            local pname="boot"
            if [ -n "${{AVB_BOOT_PARTITION_NAME:-}}" ] && [ "${{AVB_BOOT_PARTITION_NAME}}" != "boot" ]; then
              echo "Note: Overrides for AVB_BOOT_PARTITION_NAME=${{AVB_BOOT_PARTITION_NAME}} is unsupported; using boot"
            fi
            local algo="${{AVB_BOOT_ALGORITHM:-SHA256_RSA4096}}"
            local psize="${{AVB_BOOT_PARTITION_SIZE:-}}"

            # Footer props assemble
            local props=()
            if [ -n "${{OS_VERSION:-}}" ]; then
              props+=( "--prop" "com.android.build.boot.os_version:${{OS_VERSION}}" )
            fi
            if [ -n "${{FINGERPRINT:-}}" ]; then
              props+=( "--prop" "com.android.build.boot.fingerprint:${{FINGERPRINT}}" )
            fi
            if [ -n "${{SPL_DATE:-}}" ]; then
              props+=( "--prop" "com.android.build.boot.security_patch:${{SPL_DATE}}" )
            fi

            # Partition_size (calculated if not overrided)
            if [ -z "$psize" ]; then
              local size0
              size0=$(stat -c%s "$img" 2>/dev/null || stat -f%z "$img" 2>/dev/null || wc -c < "$img" 2>/dev/null) || size0=0
              local lo=$size0
              local hi=$(( size0 + 65536 ))
              avb_calc() {{
                avbtool add_hash_footer --image "$img" \
                  --partition_name "$pname" \
                  --partition_size "$1" \
                  --algorithm "$algo" \
                  --do_not_append_vbmeta_image --calc_max_image_size 2>/dev/null || echo 0
              }}
              local fit
              fit=$(avb_calc "$hi")
              while [ "${{fit:-0}}" -lt "$size0" ]; do hi=$((hi*2)); fit=$(avb_calc "$hi"); done
              while [ $lo -lt $hi ]; do
                local mid=$(((lo+hi)/2))
                fit=$(avb_calc "$mid")
                if [ "${{fit:-0}}" -ge "$size0" ]; then hi=$mid; else lo=$((mid+1)); fi
              done
              psize=$lo
            fi

            # Replace footer; sign.
            avbtool erase_footer --image "$img" >/dev/null 2>&1 || true
            avbtool add_hash_footer \
              --image "$img" \
              --partition_name "$pname" \
              --partition_size "$psize" \
              --algorithm "$algo" \
              --key "${{AVB_BOOT_KEY}}" \
              ${{AVB_BOOT_ROLLBACK_INDEX:+--rollback_index $AVB_BOOT_ROLLBACK_INDEX}} \
              "${{props[@]}}"
          }}
          sign_one "${{DIST_DIR}}/boot.img"
          sign_one "${{DIST_DIR}}/boot-gz.img"
          sign_one "${{DIST_DIR}}/boot-lz4.img"
        fi
    """.format(
        build_utils_sh = ctx.file._build_utils_sh.path,
        dist_dir = dist_dir,
        images = " ".join([image.path for image in images]),
        out_dir = out_dir,
        kernel_release = kernel_release.path,
        quoted_gki_kernel_cmdline = shell.quote(ctx.attr.gki_kernel_cmdline),
        quoted_arch = shell.quote(ctx.attr.arch),
        mkbootimg = ctx.file.mkbootimg.path,
        testkey = ctx.file._testkey.path,
        size_cmd = size_cmd,
        avb_env_cmd = avb_env_cmd,
        skip_avb_cmd = skip_avb_cmd,
    )

    if ctx.attr.arch == "arm64":
        utils.compare_file_names(
            outs,
            GKI_ARTIFACTS_AARCH64_OUTS,
            what = "{}: Internal error: not producing the expected list of outputs".format(ctx.label),
        )

    os_version_value = ""
    if ctx.attr.os_version_setting:
        info = ctx.attr.os_version_setting[PropsBuildSettingInfo]
        if info and info.value:
            os_version_value = info.value

    fingerprint_value = ""
    if ctx.attr.fingerprint_setting:
        info = ctx.attr.fingerprint_setting[PropsBuildSettingInfo]
        if info and info.value:
            fingerprint_value = info.value

    spl_date_value = ""
    if ctx.attr.spl_date_setting:
        info = ctx.attr.spl_date_setting[PropsBuildSettingInfo]
        if info and info.value:
            spl_date_value = info.value

    env_for_action = {}
    if os_version_value:
        env_for_action["OS_VERSION"] = os_version_value
    if fingerprint_value:
        env_for_action["FINGERPRINT"] = fingerprint_value
    if spl_date_value:
        env_for_action["SPL_DATE"] = spl_date_value
    rb_idx = ctx.attr._avb_boot_rollback_index[BuildSettingInfo].value
    if rb_idx and rb_idx != "0":
        env_for_action["AVB_BOOT_ROLLBACK_INDEX"] = rb_idx
    # AVB label-mode / env connections
    # Preferred label-mode; string path fallback
    use_label = ctx.attr._avb_key_use_label[BuildSettingInfo].value
    avb_key_str = ctx.attr._avb_boot_key[BuildSettingInfo].value
    if use_label:
        # Key file availablity in to the sandbox; export it
        inputs = inputs + [ctx.file._avb_boot_key_file]
        env_for_action["AVB_BOOT_KEY"] = ctx.file._avb_boot_key_file.path
    elif avb_key_str:
        env_for_action["AVB_BOOT_KEY"] = avb_key_str

    # Pass through if key
    if "AVB_BOOT_KEY" in env_for_action:
        env_for_action["AVB_BOOT_ALGORITHM"] = (
            ctx.attr._avb_boot_algorithm[BuildSettingInfo].value or "SHA256_RSA4096"
        )
        env_for_action["AVB_BOOT_PARTITION_NAME"] = (
            ctx.attr._avb_boot_partition_name[BuildSettingInfo].value or "boot"
        )
        if boot_partition_size_value:
            env_for_action["AVB_BOOT_PARTITION_SIZE"] = str(boot_partition_size_value)

    ctx.actions.run_shell(
        command = command,
        inputs = inputs,
        outputs = outs,
        tools = depset(tools, transitive = transitive_tools),
        mnemonic = "GkiArtifacts",
        progress_message = "Building GKI artifacts {}".format(ctx.label),
        env = env_for_action,
    )

    return [
        DefaultInfo(files = depset(outs)),
        OutputGroupInfo(
            boot_lz4 = depset([boot_lz4] if boot_lz4 else []),
            boot_gz = depset([boot_gz] if boot_gz else []),
        ),
    ]

gki_artifacts = rule(
    implementation = _gki_artifacts_impl,
    doc = "`BUILD_GKI_ARTIFACTS`. Build boot images and optionally `boot-img.tar.gz` as default outputs.",
    attrs = {
        "kernel_build": attr.label(
            providers = [KernelBuildUnameInfo],
            doc = "The [`kernel_build`](#kernel_build) that provides all `Image` and `Image.*`.",
        ),
        "mkbootimg": attr.label(
            allow_single_file = True,
            default = "//tools/mkbootimg:mkbootimg.py",
            doc = "path to the `mkbootimg.py` script; `MKBOOTIMG_PATH`.",
        ),
        "boot_img_sizes": attr.string_dict(
            doc = """A dictionary, with key is the compression algorithm, and value
is the size of the boot image.

For example:
```
{
    "":    str(64 * 1024 * 1024), # For Image and boot.img
    "lz4": str(64 * 1024 * 1024), # For Image.lz4 and boot-lz4.img
}
```
""",
        ),
        "gki_kernel_cmdline": attr.string(doc = "`GKI_KERNEL_CMDLINE`."),
        "arch": attr.string(
            doc = "`ARCH`.",
            values = [
                "arm64",
                "riscv64",
                "x86_64",
                # We don't have 32-bit GKIs
            ],
            mandatory = True,
        ),
        "_build_utils_sh": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel:build_utils"),
            cfg = "exec",
        ),
        "os_version_setting": attr.label(
            default = Label("//build/kernel/kleaf:os_version"),
            cfg = "host",
        ),
        "fingerprint_setting": attr.label(
            default = Label("//build/kernel/kleaf:fingerprint"),
            cfg = "host",
        ),
        "spl_date_setting": attr.label(
            default = Label("//build/kernel/kleaf:spl_date"),
            cfg = "host",
        ),
	"boot_partition_size_setting": attr.label(
            default = Label("//build/kernel/kleaf:boot_partition_size"),
            cfg = "host",
        ),
        "_avb_boot_partition_size": attr.label(
            default = Label("//build/kernel/kleaf:avb_boot_partition_size"),
            cfg = "host",
        ),
        "_avb_boot_rollback_index": attr.label(
            default = Label("//build/kernel/kleaf:avb_boot_rollback_index"),
            cfg = "host",
        ),
        "_avb_key_use_label": attr.label(default = "//build/kernel/kleaf:avb_key_use_label"),
        "_avb_boot_key": attr.label(default = "//build/kernel/kleaf:avb_boot_key"),
        "_avb_boot_algorithm": attr.label(default = "//build/kernel/kleaf:avb_boot_algorithm"),
        "_avb_boot_partition_name": attr.label(default = "//build/kernel/kleaf:avb_boot_partition_name"),
        # This input: avb_key_use_label=true
        # Default: --override_repository=avb_key_repo=/ABS-PATH/TO/KEY (export in BUILD.bazel over there)
        "_avb_boot_key_file": attr.label(
            default = Label("@avb_key_repo//:avb_key_rsa4096.pem"),
            allow_single_file = True,
        ),
        "_gcov": attr.label(default = "//build/kernel/kleaf:gcov"),
        "_testkey": attr.label(default = "//tools/mkbootimg:gki/testdata/testkey_rsa4096.pem", allow_single_file = True),
    },
    toolchains = [hermetic_toolchain.type],
)

def _gki_artifacts_prebuilts_impl(ctx):
    # Assuming the rule specifies `outs = ["subdir/gki-info.txt"]`

    srcs_map = {src.basename: src for src in ctx.files.srcs}

    # missing_outs: {"subidr/gki-info.txt": File(...)}, excluding those already in srcs
    missing_outs = {}

    # default_info_files: [File(...)]
    default_info_files = []
    for out in ctx.attr.outs:
        out_basename = paths.basename(out)
        if out_basename not in srcs_map:
            out_file = ctx.actions.declare_file("{}/{}".format(ctx.label.name, out))
            default_info_files.append(out_file)
            missing_outs[out] = out_file
        else:
            default_info_files.append(srcs_map[out_basename])

    if missing_outs:
        hermetic_tools = hermetic_toolchain.get(ctx)

        boot_img_tar = srcs_map["boot-img.tar.gz"]

        # The result of ctx.actions.declare_directory(ctx.label.name).path without declaring it
        ruledir = paths.join(
            ctx.bin_dir.path,
            paths.dirname(ctx.build_file_path),
            ctx.attr.name,
        )

        cmd = hermetic_tools.setup + """
            mkdir -p {intermediates_dir}
            tar xf {boot_img_tar} -C {intermediates_dir}
            {search_and_cp_output} --srcdir {intermediates_dir} --dstdir {ruledir} {outs}
        """.format(
            boot_img_tar = boot_img_tar.path,
            intermediates_dir = utils.intermediates_dir(ctx),
            search_and_cp_output = ctx.executable._search_and_cp_output.path,
            ruledir = ruledir,
            outs = " ".join(missing_outs.keys()),
        )

        ctx.actions.run_shell(
            inputs = [boot_img_tar],
            outputs = missing_outs.values(),
            tools = depset([ctx.executable._search_and_cp_output], transitive = [hermetic_tools.deps]),
            command = cmd,
            progress_message = "Extracting prebuilt boot-img.tar.gz {}".format(ctx.label),
            mnemonic = "GkiArtifactsPrebuiltsExtract",
        )

    return DefaultInfo(files = depset(default_info_files))

gki_artifacts_prebuilts = rule(
    implementation = _gki_artifacts_prebuilts_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "outs": attr.string_list(),
        "_search_and_cp_output": attr.label(
            default = Label("//build/kernel/kleaf:search_and_cp_output"),
            cfg = "exec",
            executable = True,
        ),
    },
    toolchains = [hermetic_toolchain.type],
)
