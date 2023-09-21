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

from optparse import OptionParser
from optparse import Option, OptionValueError
import os
import mini_parser
import re
import shutil
import sys
import tempfile

'''
Verify that Treble compatibility are not broken.
'''


#############################################################
# Tests
#############################################################

###
# Make sure that any new public type introduced in the new policy that was not
# present in the old policy has been recorded in the mapping file.
def TestNoUnmappedNewTypes(base_pub_policy, old_pub_policy, mapping):
    newt = base_pub_policy.types - old_pub_policy.types
    ret = ""
    violators = []

    for n in newt:
        if mapping.rTypeattributesets.get(n) is None:
            violators.append(n)

    if len(violators) > 0:
        ret += "SELinux: The following public types were found added to the "
        ret += "policy without an entry into the compatibility mapping file(s) "
        ret += "found in private/compat/V.v/V.v[.ignore].cil, where V.v is the "
        ret += "latest API level.\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n\n"
        ret += "See examples of how to fix this:\n"
        ret += "https://android-review.googlesource.com/c/platform/system/sepolicy/+/781036\n"
        ret += "https://android-review.googlesource.com/c/platform/system/sepolicy/+/852612\n"
    return ret

###
# Make sure that any public type removed in the current policy has its
# declaration added to the mapping file for use in non-platform policy
def TestNoUnmappedRmTypes(base_pub_policy, old_pub_policy, mapping):
    rmt = old_pub_policy.types - base_pub_policy.types
    ret = ""
    violators = []

    for o in rmt:
        if o in mapping.pubtypes and not o in mapping.types:
            violators.append(o)

    if len(violators) > 0:
        ret += "SELinux: The following formerly public types were removed from "
        ret += "policy without a declaration in the compatibility mapping "
        ret += "found in private/compat/V.v/V.v[.ignore].cil, where V.v is the "
        ret += "latest API level.\n"
        ret += " ".join(str(x) for x in sorted(violators)) + "\n\n"
        ret += "See examples of how to fix this:\n"
        ret += "https://android-review.googlesource.com/c/platform/system/sepolicy/+/822743\n"
    return ret

def TestTrebleCompatMapping(base_pub_policy, old_pub_policy, mapping):
    ret = TestNoUnmappedNewTypes(base_pub_policy, old_pub_policy, mapping)
    ret += TestNoUnmappedRmTypes(base_pub_policy, old_pub_policy, mapping)
    return ret

###
# extend OptionParser to allow the same option flag to be used multiple times.
# This is used to allow multiple file_contexts files and tests to be
# specified.
#
class MultipleOption(Option):
    ACTIONS = Option.ACTIONS + ("extend",)
    STORE_ACTIONS = Option.STORE_ACTIONS + ("extend",)
    TYPED_ACTIONS = Option.TYPED_ACTIONS + ("extend",)
    ALWAYS_TYPED_ACTIONS = Option.ALWAYS_TYPED_ACTIONS + ("extend",)

    def take_action(self, action, dest, opt, value, values, parser):
        if action == "extend":
            values.ensure_value(dest, []).append(value)
        else:
            Option.take_action(self, action, dest, opt, value, values, parser)

def do_main():
    usage = "treble_sepolicy_tests "
    usage += "-b base_pub_policy -o old_pub_policy "
    usage += "-m mapping file [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-b", "--base-pub-policy", dest="base_pub_policy",
                      metavar="FILE")
    parser.add_option("-m", "--mapping", dest="mapping", metavar="FILE")
    parser.add_option("-o", "--old-pub-policy", dest="old_pub_policy",
                      metavar="FILE")

    (options, args) = parser.parse_args()

    # Mapping files and public platform policy are only necessary for the
    # TrebleCompatMapping test.
    if not options.mapping:
        sys.exit("Must specify a compatibility mapping file\n"
                    + parser.usage)
    if not options.old_pub_policy:
        sys.exit("Must specify the previous public policy .cil file\n"
                    + parser.usage)
    if not options.base_pub_policy:
        sys.exit("Must specify the current platform-only public policy "
                    + ".cil file\n" + parser.usage)
    mapping = mini_parser.MiniCilParser(options.mapping)
    base_pub_policy = mini_parser.MiniCilParser(options.base_pub_policy)
    old_pub_policy = mini_parser.MiniCilParser(options.old_pub_policy)

    results = TestTrebleCompatMapping(base_pub_policy, old_pub_policy, mapping)

    if len(results) > 0:
        sys.exit(results)

if __name__ == '__main__':
    do_main()
