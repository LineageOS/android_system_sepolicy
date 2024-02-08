# Copyright 2023 The Android Open Source Project
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
"""Tests for apex_sepolicy_tests"""

import re
import shutil
import tempfile
import unittest

import apex_sepolicy_tests as apex
import policy


# pylint: disable=missing-docstring
class ApexSepolicyTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.mkdtemp()
        lib_path = apex.extract_data(apex.LIBSEPOLWRAP, cls.temp_dir)
        policy_path = apex.extract_data('precompiled_sepolicy', cls.temp_dir)
        cls.pol = policy.Policy(policy_path, None,  lib_path)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.temp_dir)

    # helpers

    @property
    def pol(self):
        return self.__class__.pol

    def assert_ok(self, line: str):
        errors = apex.check_line(self.pol, line, apex.all_rules)
        self.assertEqual(errors, [], "Should be no errors")

    def assert_error(self, line: str, expected_error: str):
        pattern = re.compile(expected_error)
        errors = apex.check_line(self.pol, line, apex.all_rules)
        for err in errors:
            if re.search(pattern, err):
                return
        self.fail(f"Expected error '{expected_error}' is not found in {errors}")

    # tests

    def test_parse_lines(self):
        self.assert_ok('# commented line')
        self.assert_ok('') # empty line
        self.assert_error('./path1 invalid_contexts',
                          r'Error: invalid file_contexts: .*')
        self.assert_error('./path1 u:object_r:vendor_file',
                          r'Error: invalid file_contexts: .*')
        self.assert_ok('./path1 u:object_r:vendor_file:s0')

    def test_vintf(self):
        self.assert_ok('./etc/vintf/fragment.xml u:object_r:vendor_configs_file:s0')
        self.assert_error('./etc/vintf/fragment.xml u:object_r:vendor_file:s0',
                          r'Error: \./etc/vintf/fragment\.xml: .* can\'t read')

    def test_permissions(self):
        self.assert_ok('./etc/permissions/permisssion.xml u:object_r:vendor_configs_file:s0')
        self.assert_error('./etc/permissions/permisssion.xml u:object_r:vendor_file:s0',
                          r'Error: \./etc/permissions/permisssion.xml: .* can\'t read')

    def test_initscripts(self):
        # here, netd_service is chosen randomly for invalid label for a file

        # init reads .rc file
        self.assert_ok('./etc/init.rc u:object_r:vendor_file:s0')
        self.assert_error('./etc/init.rc u:object_r:netd_service:s0',
                          r'Error: .* can\'t read')
        # init reads .#rc file
        self.assert_ok('./etc/init.32rc u:object_r:vendor_file:s0')
        self.assert_error('./etc/init.32rc u:object_r:netd_service:s0',
                          r'Error: .* can\'t read')
        # init skips file with unknown extension => no errors
        self.assert_ok('./etc/init.x32rc u:object_r:vendor_file:s0')
        self.assert_ok('./etc/init.x32rc u:object_r:netd_service:s0')

    def test_linkerconfig(self):
        self.assert_ok('./etc/linker.config.pb u:object_r:system_file:s0')
        self.assert_ok('./etc/linker.config.pb u:object_r:linkerconfig_file:s0')
        self.assert_error('./etc/linker.config.pb u:object_r:vendor_file:s0',
                        r'Error: .*linkerconfig.* can\'t read')
        self.assert_error('./ u:object_r:apex_data_file:s0',
                        r'Error: .*linkerconfig.* can\'t search')

    def test_unknown_label(self):
        self.assert_error('./bin/hw/foo u:object_r:foo_exec:s0',
                        r'Error: \./bin/hw/foo: tcontext\(foo_exec\) is unknown')

    def test_binaries(self):
        self.assert_ok('./bin/init u:object_r:init_exec:s0')
        self.assert_ok('./bin/hw/svc u:object_r:init_exec:s0')
        self.assert_error('./bin/hw/svc u:object_r:vendor_file:s0',
                          r"Error: .*svc: can\'t be labelled as \'vendor_file\'")

if __name__ == '__main__':
    unittest.main(verbosity=2)
