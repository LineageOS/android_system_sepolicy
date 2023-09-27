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
"""Tests for policy"""

import unittest
from policy import MatchPathPrefix

# pylint: disable=missing-docstring
class PolicyTests(unittest.TestCase):
    def assertMatches(self, path, prefix):
        self.assertTrue(MatchPathPrefix(path, prefix))

    def assertDoesNotMatch(self, path, prefix):
        self.assertFalse(MatchPathPrefix(path, prefix))

    # tests

    def test_match_path_prefix(self):
        # check common prefix heuristics
        self.assertMatches("/(vendor|system/vendor)/bin/sh", "/vendor/bin")
        self.assertMatches("/(vendor|system/vendor)/bin/sh", "/system/vendor/bin"),
        self.assertMatches("/(odm|vendor/odm)/etc/selinux", "/odm/etc"),
        self.assertMatches("/(odm|vendor/odm)/etc/selinux", "/vendor/odm/etc"),
        self.assertMatches("/(system_ext|system/system_ext)/bin/foo", "/system_ext/bin"),
        self.assertMatches("/(system_ext|system/system_ext)/bin/foo", "/system/system_ext/bin"),
        self.assertMatches("/(product|system/product)/lib/libc.so", "/product/lib"),
        self.assertMatches("/(product|system/product)/lib/libc.so", "/system/product/lib"),
        self.assertDoesNotMatch("/(vendor|system/vendor)/bin/sh", "/system/bin"),
        self.assertDoesNotMatch("/(odm|vendor/odm)/etc/selinux", "/vendor/etc"),
        self.assertDoesNotMatch("/(system_ext|system/system_ext)/bin/foo", "/system/bin"),
        self.assertDoesNotMatch("/(product|system/product)/lib/libc.so", "/system/lib"),

        # check generic regex
        self.assertMatches("(/.*)+", "/system/etc/vintf")
        self.assertDoesNotMatch("(/.*)+", "foo/bar/baz")

        self.assertMatches("/(system|product)/lib(64)?(/.*)+.*\.so", "/system/lib/hw/libbaz.so")
        self.assertMatches("/(system|product)/lib(64)?(/.*)+.*\.so", "/system/lib64/")
        self.assertMatches("/(system|product)/lib(64)?(/.*)+.*\.so", "/product/lib/hw/libbaz.so")
        self.assertMatches("/(system|product)/lib(64)?(/.*)+.*\.so", "/product/lib64/")
        self.assertDoesNotMatch("/(system|product)/lib(64)?(/.*)+.*\.so", "/vendor/lib/hw/libbaz.so")
        self.assertDoesNotMatch("/(system|product)/lib(64)?(/.*)+.*\.so", "/odm/lib64/")

if __name__ == '__main__':
    unittest.main(verbosity=2)
