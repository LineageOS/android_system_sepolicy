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
import pkgutil
import policy
from policy import MatchPathPrefix
import re
import shutil
import sys
import tempfile

DEBUG=False
SHARED_LIB_EXTENSION = '.dylib' if sys.platform == 'darwin' else '.so'

'''
Verify that Treble compatibility are not broken.
'''


#############################################################
# Tests
#############################################################

###
# Make sure that any new public type introduced in the new policy that was not
# present in the old policy has been recorded in the mapping file.
def TestNoUnmappedNewTypes(test_policy):
    newt = test_policy.alltypes - test_policy.oldalltypes
    ret = ""
    violators = []

    for n in newt:
        if n in test_policy.pubtypes and test_policy.compatMapping.rTypeattributesets.get(n) is None:
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
def TestNoUnmappedRmTypes(test_policy):
    rmt = test_policy.oldalltypes - test_policy.alltypes
    ret = ""
    violators = []

    for o in rmt:
        if o in test_policy.compatMapping.pubtypes and not o in test_policy.compatMapping.types:
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

def TestTrebleCompatMapping(test_policy):
    ret = TestNoUnmappedNewTypes(test_policy)
    ret += TestNoUnmappedRmTypes(test_policy)
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

def do_main(libpath):
    """
    Args:
        libpath: string, path to libsepolwrap.so
    """
    test_policy = policy.TestPolicy()

    usage = "treble_sepolicy_tests "
    usage += "-p curr_policy -b base_policy -o old_policy "
    usage += "-m mapping file [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-b", "--basepolicy", dest="basepolicy", metavar="FILE")
    parser.add_option("-u", "--base-pub-policy", dest="base_pub_policy",
                      metavar="FILE")
    parser.add_option("-m", "--mapping", dest="mapping", metavar="FILE")
    parser.add_option("-o", "--oldpolicy", dest="oldpolicy", metavar="FILE")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")

    (options, args) = parser.parse_args()

    if not options.policy:
        sys.exit("Must specify current monolithic policy file\n" + parser.usage)
    if not os.path.exists(options.policy):
        sys.exit("Error: policy file " + options.policy + " does not exist\n"
                + parser.usage)

    # Mapping files and public platform policy are only necessary for the
    # TrebleCompatMapping test.
    if not options.basepolicy:
        sys.exit("Must specify the current platform-only policy file\n"
                    + parser.usage)
    if not options.mapping:
        sys.exit("Must specify a compatibility mapping file\n"
                    + parser.usage)
    if not options.oldpolicy:
        sys.exit("Must specify the previous monolithic policy file\n"
                    + parser.usage)
    if not options.base_pub_policy:
        sys.exit("Must specify the current platform-only public policy "
                    + ".cil file\n" + parser.usage)
    basepol = policy.Policy(options.basepolicy, None, libpath)
    oldpol = policy.Policy(options.oldpolicy, None, libpath)
    mapping = mini_parser.MiniCilParser(options.mapping)
    pubpol = mini_parser.MiniCilParser(options.base_pub_policy)
    test_policy.compatSetup(basepol, oldpol, mapping, pubpol.types)

    pol = policy.Policy(options.policy, None, libpath)
    test_policy.setup(pol)

    if DEBUG:
        test_policy.PrintScontexts()

    results = TestTrebleCompatMapping(test_policy)

    if len(results) > 0:
        sys.exit(results)

if __name__ == '__main__':
    temp_dir = tempfile.mkdtemp()
    try:
        libname = "libsepolwrap" + SHARED_LIB_EXTENSION
        libpath = os.path.join(temp_dir, libname)
        with open(libpath, "wb") as f:
            blob = pkgutil.get_data("treble_sepolicy_tests", libname)
            if not blob:
                sys.exit("Error: libsepolwrap does not exist. Is this binary corrupted?\n")
            f.write(blob)
        do_main(libpath)
    finally:
        shutil.rmtree(temp_dir)
