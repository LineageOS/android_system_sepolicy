from optparse import OptionParser
from optparse import Option, OptionValueError
import os
import policy
import re
import sys

#############################################################
# Tests
#############################################################
def TestDataTypeViolations(pol):
    return pol.AssertPathTypesHaveAttr(["/data/"], [], "data_file_type")

def TestSysfsTypeViolations(pol):
    return pol.AssertPathTypesHaveAttr(["/sys/"], ["/sys/kernel/debug/",
                                    "/sys/kernel/tracing"], "sysfs_type")

def TestDebugfsTypeViolations(pol):
    # TODO: this should apply to genfs_context entries as well
    return pol.AssertPathTypesHaveAttr(["/sys/kernel/debug/",
                                    "/sys/kernel/tracing"], [], "debugfs_type")
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

Tests = ["TestDataTypeViolators"]

if __name__ == '__main__':
    usage = "sepolicy_tests.py -f nonplat_file_contexts -f "
    usage +="plat_file_contexts -p policy [--test test] [--help]"
    parser = OptionParser(option_class=MultipleOption, usage=usage)
    parser.add_option("-f", "--file_contexts", dest="file_contexts",
            metavar="FILE", action="extend", type="string")
    parser.add_option("-p", "--policy", dest="policy", metavar="FILE")
    parser.add_option("-l", "--library-path", dest="libpath", metavar="FILE")
    parser.add_option("-t", "--test", dest="test", action="extend",
            help="Test options include "+str(Tests))

    (options, args) = parser.parse_args()

    if not options.libpath:
        sys.exit("Must specify path to host libraries\n" + parser.usage)
    if not os.path.exists(options.libpath):
        sys.exit("Error: library-path " + options.libpath + " does not exist\n"
                + parser.usage)

    if not options.policy:
        sys.exit("Must specify monolithic policy file\n" + parser.usage)
    if not os.path.exists(options.policy):
        sys.exit("Error: policy file " + options.policy + " does not exist\n"
                + parser.usage)

    if not options.file_contexts:
        sys.exit("Error: Must specify file_contexts file(s)\n" + parser.usage)
    for f in options.file_contexts:
        if not os.path.exists(f):
            sys.exit("Error: File_contexts file " + f + " does not exist\n" +
                    parser.usage)

    pol = policy.Policy(options.policy, options.file_contexts, options.libpath)

    results = ""
    # If an individual test is not specified, run all tests.
    if options.test is None or "TestDataTypeViolations" in options.tests:
        results += TestDataTypeViolations(pol)
    if options.test is None or "TestSysfsTypeViolations" in options.tests:
        results += TestSysfsTypeViolations(pol)
    if options.test is None or "TestDebugfsTypeViolations" in options.tests:
        results += TestDebugfsTypeViolations(pol)

    if len(results) > 0:
        sys.exit(results)
