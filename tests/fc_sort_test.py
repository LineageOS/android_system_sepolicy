# Copyright 2021 The Android Open Source Project
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

import unittest

import fc_sort

class FcSortTest(unittest.TestCase):

    def testGetStemLen(self):
        self.assertEqual(fc_sort.get_stem_len("/data"), 5)
        self.assertEqual(fc_sort.get_stem_len("/data/system"), 12)
        self.assertEqual(fc_sort.get_stem_len("/data/(system)?"), 6)

    def testIsMeta(self):
        self.assertEqual(fc_sort.is_meta("/data"), False)
        self.assertEqual(fc_sort.is_meta("/data$"), True)
        self.assertEqual(fc_sort.is_meta(r"\$data"), False)

    def testLesserThan(self):
        n1 = fc_sort.FileContextsNode.create("/data  u:object_r:rootfs:s0")
        # shorter stem_len
        n2 = fc_sort.FileContextsNode.create("/d  u:object_r:rootfs:s0")
        # is meta
        n3 = fc_sort.FileContextsNode.create("/data/l(/.*)? u:object_r:log:s0")
        # with file_type
        n4 = fc_sort.FileContextsNode.create("/data -- u:object_r:rootfs:s0")
        contexts = [n1, n2, n3, n4]
        contexts.sort()
        self.assertEqual(contexts, [n3, n2, n1, n4])

    def testReadFileContexts(self):
        content = """# comment
/                                     u:object_r:rootfs:s0
# another comment
/adb_keys                     u:object_r:adb_keys_file:s0
"""
        fcs = fc_sort.read_file_contexts(content.splitlines())
        self.assertEqual(len(fcs), 2)

        self.assertEqual(fcs[0].path, "/")
        self.assertEqual(fcs[0].type, "rootfs")

        self.assertEqual(fcs[1].path, "/adb_keys")
        self.assertEqual(fcs[1].type, "adb_keys_file")

if __name__ == '__main__':
    unittest.main(verbosity=2)
