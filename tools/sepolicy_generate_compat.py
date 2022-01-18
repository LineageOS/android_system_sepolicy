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
import glob
import logging
import os
import shutil
import subprocess
import tempfile
import zipfile
"""This tool generates a mapping file for {ver} core sepolicy."""


def check_run(cmd):
    logging.debug('Running cmd: %s' % cmd)
    subprocess.run(cmd, check=True)


def check_output(cmd):
    logging.debug('Running cmd: %s' % cmd)
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE)


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
    """

    cmd = [
        'debugfs', '-R',
        'cat system/etc/selinux/mapping/%s.cil' % ver, img_path
    ]
    with open(os.path.join(destination, '%s.cil' % ver), 'wb') as f:
        logging.debug('Extracting %s.cil to %s' % (ver, destination))
        f.write(check_output(cmd).stdout)


def download_mapping_file(branch, build, ver, destination='.'):
    """ Downloads system/etc/selinux/mapping/{ver}.cil from Android Build server.

    Args:
      branch: string, branch to pull build artifacts from (e.g. "sc-v2-dev")
      build: string, build ID or "latest"
      ver: string, version of designated mapping file (e.g. "32.0")
      destination: string, destination to pull build artifact to
    """
    temp_dir = tempfile.mkdtemp()

    try:
        artifact_pattern = 'aosp_arm64-img-*.zip'
        fetch_artifact(branch, build, artifact_pattern, temp_dir)

        # glob must succeed
        zip_path = glob.glob(os.path.join(temp_dir, artifact_pattern))[0]
        with zipfile.ZipFile(zip_path) as zip_file:
            logging.debug('Extracting system.img to %s' % temp_dir)
            zip_file.extract('system.img', temp_dir)

        system_img_path = os.path.join(temp_dir, 'system.img')
        extract_mapping_file_from_img(system_img_path, ver, destination)
    finally:
        logging.info('Deleting temporary dir: {}'.format(temp_dir))
        shutil.rmtree(temp_dir)


def get_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--branch',
        required=True,
        help='Branch to pull build from. e.g. "sc-v2-dev"')
    parser.add_argument('--build', required=True, help='Build ID, or "latest"')
    parser.add_argument(
        '--version',
        required=True,
        help='Version of designated mapping file. e.g. "32.0"')
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

    download_mapping_file(args.branch, args.build, args.version)


if __name__ == '__main__':
    main()
