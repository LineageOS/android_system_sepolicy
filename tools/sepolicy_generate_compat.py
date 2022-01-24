#!/usr/bin/env python3

# Copyright 2022 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import distutils.ccompiler
import glob
import logging
import mini_parser
import os
import policy
import shutil
import subprocess
import tempfile
import zipfile
"""This tool generates a mapping file for {ver} core sepolicy."""

temp_dir = ''


def check_run(cmd, cwd=None):
    if cwd:
        logging.debug('Running cmd at %s: %s' % (cwd, cmd))
    else:
        logging.debug('Running cmd: %s' % cmd)
    subprocess.run(cmd, cwd=cwd, check=True)


def check_output(cmd):
    logging.debug('Running cmd: %s' % cmd)
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE)


def get_android_build_top():
    ANDROID_BUILD_TOP = os.getenv('ANDROID_BUILD_TOP')
    if not ANDROID_BUILD_TOP:
        sys.exit(
            'Error: Missing ANDROID_BUILD_TOP env variable. Please run '
            '\'. build/envsetup.sh; lunch <build target>\'. Exiting script.')
    return ANDROID_BUILD_TOP


def fetch_artifact(branch, build, pattern, destination='.'):
    """Fetches build artifacts from Android Build server.

    Args:
      branch: string, branch to pull build artifacts from
      build: string, build ID or "latest"
      pattern: string, pattern of build artifact file name
      destination: string, destination to pull build artifact to
    """
    fetch_artifact_path = '/google/data/ro/projects/android/fetch_artifact'
    cmd = [
        fetch_artifact_path, '--branch', branch, '--target',
        'aosp_arm64-userdebug'
    ]
    if build == 'latest':
        cmd.append('--latest')
    else:
        cmd.extend(['--bid', build])
    cmd.extend([pattern, destination])
    check_run(cmd)


def extract_mapping_file_from_img(img_path, ver, destination='.'):
    """ Extracts system/etc/selinux/mapping/{ver}.cil from system.img file.

    Args:
      img_path: string, path to system.img file
      ver: string, version of designated mapping file
      destination: string, destination to pull the mapping file to

    Returns:
      string, path to extracted mapping file
    """

    cmd = [
        'debugfs', '-R',
        'cat system/etc/selinux/mapping/%s.cil' % ver, img_path
    ]
    path = os.path.join(destination, '%s.cil' % ver)
    with open(path, 'wb') as f:
        logging.debug('Extracting %s.cil to %s' % (ver, destination))
        f.write(check_output(cmd).stdout)
    return path


def download_mapping_file(branch, build, ver, destination='.'):
    """ Downloads system/etc/selinux/mapping/{ver}.cil from Android Build server.

    Args:
      branch: string, branch to pull build artifacts from (e.g. "sc-v2-dev")
      build: string, build ID or "latest"
      ver: string, version of designated mapping file (e.g. "32.0")
      destination: string, destination to pull build artifact to

    Returns:
      string, path to extracted mapping file
    """
    logging.info('Downloading %s mapping file from branch %s build %s...' %
                 (ver, branch, build))
    artifact_pattern = 'aosp_arm64-img-*.zip'
    fetch_artifact(branch, build, artifact_pattern, temp_dir)

    # glob must succeed
    zip_path = glob.glob(os.path.join(temp_dir, artifact_pattern))[0]
    with zipfile.ZipFile(zip_path) as zip_file:
        logging.debug('Extracting system.img to %s' % temp_dir)
        zip_file.extract('system.img', temp_dir)

    system_img_path = os.path.join(temp_dir, 'system.img')
    return extract_mapping_file_from_img(system_img_path, ver, destination)


def build_base_files(target_version):
    """ Builds needed base policy files from the source code.

    Args:
      target_version: string, target version to gerenate the mapping file

    Returns:
      (string, string, string), paths to base policy, old policy, and pub policy
      cil
    """
    logging.info('building base sepolicy files')
    build_top = get_android_build_top()

    cmd = [
        'build/soong/soong_ui.bash',
        '--make-mode',
        'dist',
        'base-sepolicy-files-for-mapping',
        'TARGET_PRODUCT=aosp_arm64',
        'TARGET_BUILD_VARIANT=userdebug',
    ]
    check_run(cmd, cwd=build_top)

    dist_dir = os.path.join(build_top, 'out', 'dist')
    base_policy_path = os.path.join(dist_dir, 'base_plat_sepolicy')
    old_policy_path = os.path.join(dist_dir,
                                   '%s_plat_sepolicy' % target_version)
    pub_policy_cil_path = os.path.join(dist_dir, 'base_plat_pub_policy.cil')

    return base_policy_path, old_policy_path, pub_policy_cil_path


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--branch',
        required=True,
        help='Branch to pull build from. e.g. "sc-v2-dev"')
    parser.add_argument('--build', required=True, help='Build ID, or "latest"')
    parser.add_argument(
        '--target-version',
        required=True,
        help='Target version of designated mapping file. e.g. "32.0"')
    parser.add_argument(
        '--latest-version',
        required=True,
        help='Latest version for mapping of newer types. e.g. "31.0"')
    parser.add_argument(
        '-v',
        '--verbose',
        action='count',
        default=0,
        help='Increase output verbosity, e.g. "-v", "-vv".')
    return parser.parse_args()


def main():
    args = get_args()

    verbosity = min(args.verbose, 2)
    logging.basicConfig(
        format='%(levelname)-8s [%(filename)s:%(lineno)d] %(message)s',
        level=(logging.WARNING, logging.INFO, logging.DEBUG)[verbosity])

    global temp_dir
    temp_dir = tempfile.mkdtemp()

    try:
        libpath = os.path.join(
            os.path.dirname(os.path.realpath(__file__)), 'libsepolwrap' +
            distutils.ccompiler.new_compiler().shared_lib_extension)
        if not os.path.exists(libpath):
            sys.exit(
                'Error: libsepolwrap does not exist. Is this binary corrupted?\n'
            )

        build_top = get_android_build_top()
        sepolicy_path = os.path.join(build_top, 'system', 'sepolicy')
        target_compat_path = os.path.join(sepolicy_path, 'private', 'compat',
                                          args.target_version)

        # Step 1. Download system/etc/selinux/mapping/{ver}.cil, and remove types/typeattributes
        mapping_file = download_mapping_file(args.branch, args.build,
                                             args.target_version)
        mapping_file_cil = mini_parser.MiniCilParser(mapping_file)
        mapping_file_cil.types = set()
        mapping_file_cil.typeattributes = set()

        # Step 2. Build base policy files and parse latest mapping files
        base_policy_path, old_policy_path, pub_policy_cil_path = build_base_files(
            args.target_version)
        base_policy = policy.Policy(base_policy_path, None, libpath)
        old_policy = policy.Policy(old_policy_path, None, libpath)
        pub_policy_cil = mini_parser.MiniCilParser(pub_policy_cil_path)

        all_types = base_policy.GetAllTypes(False)
        old_all_types = old_policy.GetAllTypes(False)
        pub_types = pub_policy_cil.types

        # Step 3. Find new types and removed types
        new_types = pub_types & (all_types - old_all_types)
        removed_types = (mapping_file_cil.pubtypes - mapping_file_cil.types) & (
            old_all_types - all_types)

        logging.info('new types: %s' % new_types)
        logging.info('removed types: %s' % removed_types)

        # TODO: Step 4. Map new types and removed types appropriately
    finally:
        logging.info('Deleting temporary dir: {}'.format(temp_dir))
        shutil.rmtree(temp_dir)


if __name__ == '__main__':
    main()
