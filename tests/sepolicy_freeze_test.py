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

from optparse import OptionParser
import mini_parser
import os
import sys

def do_main():
    usage = "sepolicy_freeze_test "
    usage += "-c current_cil -p prebuilt_cil [--help]"
    parser = OptionParser(usage=usage)
    parser.add_option("-c", "--current", dest="current", metavar="FILE")
    parser.add_option("-p", "--prebuilt", dest="prebuilt", metavar="FILE")

    (options, args) = parser.parse_args()

    if not options.current or not options.prebuilt:
        sys.exit("Must specify both current and prebuilt\n" + parser.usage)
    if not os.path.exists(options.current):
        sys.exit("Current policy " + options.current + " does not exist\n"
                + parser.usage)
    if not os.path.exists(options.prebuilt):
        sys.exit("Prebuilt policy " + options.prebuilt + " does not exist\n"
                + parser.usage)

    current_policy = mini_parser.MiniCilParser(options.current)
    prebuilt_policy = mini_parser.MiniCilParser(options.prebuilt)
    current_policy.typeattributes = set(filter(lambda x: "base_typeattr_" not in x,
                                               current_policy.typeattributes))
    prebuilt_policy.typeattributes = set(filter(lambda x: "base_typeattr_" not in x,
                                                prebuilt_policy.typeattributes))

    results = ""
    removed_types = prebuilt_policy.types - current_policy.types
    added_types = current_policy.types - prebuilt_policy.types
    removed_attributes = prebuilt_policy.typeattributes - current_policy.typeattributes
    added_attributes = current_policy.typeattributes - prebuilt_policy.typeattributes

    # TODO(b/330670954): remove this once all internal references are removed.
    if "proc_compaction_proactiveness" in added_types:
        added_types.remove("proc_compaction_proactiveness")

    if removed_types:
        results += "The following public types were removed:\n" + ", ".join(removed_types) + "\n"

    if added_types:
        results += "The following public types were added:\n" + ", ".join(added_types) + "\n"

    if removed_attributes:
        results += "The following public attributes were removed:\n" + ", ".join(removed_attributes) + "\n"

    if added_attributes:
        results += "The following public attributes were added:\n" + ", ".join(added_attributes) + "\n"

    if results:
        sys.exit(f'''{results}
******************************
You have tried to change system/sepolicy/public after vendor API freeze.
To make these errors go away, you can guard types and attributes listed above,
so they won't be included to the release build.

See an example of how to guard them:
    https://android-review.googlesource.com/3050544
******************************
''')

if __name__ == '__main__':
    do_main()
