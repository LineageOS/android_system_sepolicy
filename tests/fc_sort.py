#!/usr/bin/env python3
#
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

import argparse
import os
import sys


META_CHARS = frozenset(['.', '^', '$', '?', '*', '+', '|', '[', '(', '{'])
ESCAPED_META_CHARS = frozenset([ '\\{}'.format(c) for c in META_CHARS ])


def get_stem_len(path):
    """Returns the length of the stem."""
    stem_len = 0
    i = 0
    while i < len(path):
        if path[i] == "\\":
            i += 1
        elif path[i] in META_CHARS:
            break
        stem_len += 1
        i += 1
    return stem_len


def is_meta(path):
    """Indicates if a path contains any metacharacter."""
    meta_char_count = 0
    escaped_meta_char_count = 0
    for c in META_CHARS:
        if c in path:
            meta_char_count += 1
    for c in ESCAPED_META_CHARS:
        if c in path:
            escaped_meta_char_count += 1
    return meta_char_count > escaped_meta_char_count


class FileContextsNode(object):
    """An entry in a file_context file."""

    def __init__(self, path, file_type, context, meta, stem_len, str_len, line):
        self.path = path
        self.file_type = file_type
        self.context = context
        self.meta = meta
        self.stem_len = stem_len
        self.str_len = str_len
        self.type = context.split(":")[2]
        self.line = line

    @classmethod
    def create(cls, line):
        if (len(line) == 0) or (line[0] == '#'):
            return None

        split = line.split()
        path = split[0].strip()
        context = split[-1].strip()
        file_type = None
        if len(split) == 3:
            file_type = split[1].strip()
        meta = is_meta(path)
        stem_len = get_stem_len(path)
        str_len = len(path.replace("\\", ""))

        return cls(path, file_type, context, meta, stem_len, str_len, line)

    # Comparator function based off fc_sort.c
    def __lt__(self, other):
        # The regex without metachars is more specific.
        if self.meta and not other.meta:
            return True
        if other.meta and not self.meta:
            return False

        # The regex with longer stem_len (regex before any meta characters) is
        # more specific.
        if self.stem_len < other.stem_len:
            return True
        if other.stem_len < self.stem_len:
            return False

        # The regex with longer string length is more specific
        if self.str_len < other.str_len:
            return True
        if other.str_len < self.str_len:
            return False

        # A regex with a file_type defined (e.g. file, dir) is more specific.
        if self.file_type is None and other.file_type is not None:
            return True
        if other.file_type is None and self.file_type is not None:
            return False

        return False


def read_file_contexts(file_descriptor):
    file_contexts = []
    for line in file_descriptor:
        node = FileContextsNode.create(line.strip())
        if node is not None:
            file_contexts.append(node)
    return file_contexts


def read_multiple_file_contexts(files):
    file_contexts = []
    for filename in files:
        with open(filename) as fd:
            file_contexts.extend(read_file_contexts(fd))
    return file_contexts


def sort(files):
    for f in files:
        if not os.path.exists(f):
            sys.exit("Error: File_contexts file " + f + " does not exist\n")
    file_contexts = read_multiple_file_contexts(files)
    file_contexts.sort()
    return file_contexts


def print_fc(fc, out):
    if not out:
        f = sys.stdout
    else:
        f = open(out, "w")
    for node in fc:
        f.write(node.line + "\n")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
            description="SELinux file_contexts sorting tool.")
    parser.add_argument("-i", dest="input", nargs="*",
            help="Path to the file_contexts file(s).")
    parser.add_argument("-o", dest="output", help="Path to the output file.")
    args = parser.parse_args()
    if not args.input:
        parser.error("Must include path to policy")

    print_fc(sort(args.input), args.output)
