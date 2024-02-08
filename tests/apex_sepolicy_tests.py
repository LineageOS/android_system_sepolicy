#!/usr/bin/env python3
#
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
""" A tool to test APEX file_contexts

Usage:
    $ deapexer list -Z foo.apex > /tmp/fc
    $ apex_sepolicy_tests -f /tmp/fc
"""


import argparse
import os
import pathlib
import pkgutil
import re
import sys
import tempfile
from dataclasses import dataclass
from typing import List

import policy


SHARED_LIB_EXTENSION = '.dylib' if sys.platform == 'darwin' else '.so'
LIBSEPOLWRAP = "libsepolwrap" + SHARED_LIB_EXTENSION


@dataclass
class Is:
    """Exact matcher for a path."""
    path: str


@dataclass
class Glob:
    """Path matcher with pathlib.PurePath.match"""
    pattern: str


@dataclass
class Regex:
    """Path matcher with re.match"""
    pattern: str


@dataclass
class BinaryFile:
    pass


Matcher = Is | Glob | Regex | BinaryFile


# predicate functions for Func matcher


@dataclass
class AllowPerm:
    """Rule checking if scontext has 'perm' to the entity"""
    tclass: str
    scontext: set[str]
    perm: str


@dataclass
class ResolveType:
    """Rule checking if type can be resolved"""
    pass


@dataclass
class NotAnyOf:
    """Rule checking if entity is not labelled as any of the given labels"""
    labels: set[str]


Rule = AllowPerm | ResolveType | NotAnyOf


# Helper for 'read'
def AllowRead(tclass, scontext):
    return AllowPerm(tclass, scontext, 'read')


def match_path(path: str, matcher: Matcher) -> bool:
    """True if path matches with the given matcher"""
    match matcher:
        case Is(target):
            return path == target
        case Glob(pattern):
            return pathlib.PurePath(path).match(pattern)
        case Regex(pattern):
            return re.match(pattern, path)
        case BinaryFile:
            return path.startswith('./bin/') and not path.endswith('/')


def check_rule(pol, path: str, tcontext: str, rule: Rule) -> List[str]:
    """Returns error message if scontext can't read the target"""
    errors = []
    match rule:
        case AllowPerm(tclass, scontext, perm):
            # Test every source in scontext(set)
            for s in scontext:
                te_rules = list(pol.QueryTERule(scontext={s},
                                                tcontext={tcontext},
                                                tclass={tclass},
                                                perms={perm}))
                if len(te_rules) > 0:
                    continue  # no errors

                errors.append(f"Error: {path}: {s} can't {perm}. (tcontext={tcontext})")
        case ResolveType():
            if tcontext not in pol.GetAllTypes(False):
                errors.append(f"Error: {path}: tcontext({tcontext}) is unknown")
        case NotAnyOf(labels):
            if tcontext in labels:
                errors.append(f"Error: {path}: can't be labelled as '{tcontext}'")
    return errors


target_specific_rules = [
    (Glob('*'), ResolveType()),
]


generic_rules = [
    # binaries should be executable
    (BinaryFile, NotAnyOf({'vendor_file'})),
    # permissions
    (Is('./etc/permissions/'), AllowRead('dir', {'system_server'})),
    (Glob('./etc/permissions/*.xml'), AllowRead('file', {'system_server'})),
    # init scripts with optional SDK version (e.g. foo.rc, foo.32rc)
    (Regex('\./etc/.*\.\d*rc'), AllowRead('file', {'init'})),
    # vintf fragments
    (Is('./etc/vintf/'), AllowRead('dir', {'servicemanager', 'apexd'})),
    (Glob('./etc/vintf/*.xml'), AllowRead('file', {'servicemanager', 'apexd'})),
    # ./ and apex_manifest.pb
    (Is('./apex_manifest.pb'), AllowRead('file', {'linkerconfig', 'apexd'})),
    (Is('./'), AllowPerm('dir', {'linkerconfig', 'apexd'}, 'search')),
    # linker.config.pb
    (Is('./etc/linker.config.pb'), AllowRead('file', {'linkerconfig'})),
]


all_rules = target_specific_rules + generic_rules


def check_line(pol: policy.Policy, line: str, rules) -> List[str]:
    """Parses a file_contexts line and runs checks"""
    # skip empty/comment line
    line = line.strip()
    if line == '' or line[0] == '#':
        return []

    # parse
    split = line.split()
    if len(split) != 2:
        return [f"Error: invalid file_contexts: {line}"]
    path, context = split[0], split[1]
    if len(context.split(':')) != 4:
        return [f"Error: invalid file_contexts: {line}"]
    tcontext = context.split(':')[2]

    # check rules
    errors = []
    for matcher, rule in rules:
        if match_path(path, matcher):
            errors.extend(check_rule(pol, path, tcontext, rule))
    return errors


def extract_data(name, temp_dir):
    out_path = os.path.join(temp_dir, name)
    with open(out_path, 'wb') as f:
        blob = pkgutil.get_data('apex_sepolicy_tests', name)
        if not blob:
            sys.exit(f"Error: {name} does not exist. Is this binary corrupted?\n")
        f.write(blob)
    return out_path


def do_main(work_dir):
    """Do testing"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--all', action='store_true', help='tests ALL aspects')
    parser.add_argument('-f', '--file_contexts', help='output of "deapexer list -Z"')
    args = parser.parse_args()

    lib_path = extract_data(LIBSEPOLWRAP, work_dir)
    policy_path = extract_data('precompiled_sepolicy', work_dir)
    pol = policy.Policy(policy_path, None, lib_path)

    if args.all:
        rules = all_rules
    else:
        rules = generic_rules

    errors = []
    with open(args.file_contexts, 'rt', encoding='utf-8') as file_contexts:
        for line in file_contexts:
            errors.extend(check_line(pol, line, rules))
    if len(errors) > 0:
        sys.exit('\n'.join(errors))


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as temp_dir:
        do_main(temp_dir)
