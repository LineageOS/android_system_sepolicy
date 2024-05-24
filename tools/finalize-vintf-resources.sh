#!/bin/bash

# Copyright (C) 2023 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [ $# -ne 2 ]; then
    echo "Usage: $0 <top> <ver>"
    exit 1
fi

top=$1
ver=$2

mkdir -p "$top/system/sepolicy/prebuilts/api/${ver}/"
cp -r "$top/system/sepolicy/public/" "$top/system/sepolicy/prebuilts/api/${ver}/"
cp -r "$top/system/sepolicy/private/" "$top/system/sepolicy/prebuilts/api/${ver}/"

cat > "$top/system/sepolicy/prebuilts/api/${ver}/Android.bp" <<EOF
// Automatically generated file, do not edit!
se_policy_conf {
    name: "${ver}_plat_pub_policy.conf",
    defaults: ["se_policy_conf_flags_defaults"],
    srcs: [":se_build_files{.plat_public_${ver}}", ":se_build_files{.reqd_mask}"],
    installable: false,
    build_variant: "user",
}

se_policy_cil {
    name: "${ver}_plat_pub_policy.cil",
    src: ":${ver}_plat_pub_policy.conf",
    filter_out: [":reqd_policy_mask.cil"],
    secilc_check: false,
    installable: false,
}

se_policy_conf {
    name: "${ver}_product_pub_policy.conf",
    defaults: ["se_policy_conf_flags_defaults"],
    srcs: [
        ":se_build_files{.plat_public_${ver}}",
        ":se_build_files{.system_ext_public_${ver}}",
        ":se_build_files{.product_public_${ver}}",
        ":se_build_files{.reqd_mask}",
    ],
    installable: false,
    build_variant: "user",
}

se_policy_cil {
    name: "${ver}_product_pub_policy.cil",
    src: ":${ver}_product_pub_policy.conf",
    filter_out: [":reqd_policy_mask.cil"],
    secilc_check: false,
    installable: false,
}

se_policy_conf {
    name: "${ver}_plat_policy.conf",
    defaults: ["se_policy_conf_flags_defaults"],
    srcs: [
        ":se_build_files{.plat_public_${ver}}",
        ":se_build_files{.plat_private_${ver}}",
        ":se_build_files{.system_ext_public_${ver}}",
        ":se_build_files{.system_ext_private_${ver}}",
        ":se_build_files{.product_public_${ver}}",
        ":se_build_files{.product_private_${ver}}",
    ],
    installable: false,
    build_variant: "user",
}

se_policy_cil {
    name: "${ver}_plat_policy.cil",
    src: ":${ver}_plat_policy.conf",
    additional_cil_files: [":sepolicy_technical_debt{.plat_private_${ver}}"],
    installable: false,
}

se_policy_binary {
    name: "${ver}_plat_policy",
    srcs: [":${ver}_plat_policy.cil"],
    installable: false,
    dist: {
        targets: ["base-sepolicy-files-for-mapping"],
    },
}
EOF
