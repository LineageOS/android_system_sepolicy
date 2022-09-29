#!/usr/bin/env python3
#
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

import logging
import json
import sys
import os
import argparse

def check_file_exists(file_name):
  if not os.path.exists(file_name):
    sys.exit("File doesn't exist : {0}".format(file_name))

def read_bindings(binding_file):
  check_file_exists(binding_file)
  with open(binding_file) as jsonFile:
   bindings = json.loads(jsonFile.read())
  return bindings

def check_fuzzer_exists(context_file, bindings):
  with open(context_file) as file:
    for line in file:
       # Ignore empty lines and comments
       line = line.strip()
       if line.startswith("#"):
         logging.debug("Found a comment..skipping")
         continue

       tokens = line.split()
       if len(tokens) == 0:
         logging.debug("Skipping empty lines in service_contexts")
         continue

       # For a valid service_context file, there will be only two tokens
       # First will be service name and second will be its label.
       service_name = tokens[0]
       if service_name not in bindings:
         sys.exit("\nerror: Service '{0}' is being added, but we have no fuzzer on file for it. "
                  "Fuzzers are listed at $ANDROID_BUILD_TOP/system/sepolicy/build/soong/service_fuzzer_bindings.go \n\n"
                  "NOTE: automatic service fuzzers are currently not supported in Java (b/232439254) "
                  "and Rust (b/164122727). In this case, please ignore this for now and add an entry for your"
                  "new service in service_fuzzer_bindings.go \n\n"
                  "If you are writing a new service, it may be subject to attack from other "
                  "potentially malicious processes. A fuzzer can be written automatically "
                  "by adding these things: \n"
                  "- a cc_fuzz Android.bp entry \n"
                  "- a main file that constructs your service and calls 'fuzzService' \n\n"
                  "An examples can be found here: \n"
                  "- $ANDROID_BUILD_TOP/hardware/interfaces/vibrator/aidl/default/fuzzer.cpp \n"
                  "- https://source.android.com/docs/core/architecture/aidl/aidl-fuzzing \n\n"
                  "This is only ~30 lines of configuration. It requires dependency injection "
                  "for your service which is a good practice, and (in AOSP) you will get bugs "
                  "automatically filed on you. You will find out about issues without needing "
                  "to backport changes years later, and the system will automatically find ways "
                  "to reproduce difficult to solve issues for you. \n\n"
                  "This error can be bypassed by adding entry "
                  "for new service in $ANDROID_BUILD_TOP/system/sepolicy/build/soong/service_fuzzer_bindings.go \n\n"
                  "- Android Fuzzing and Security teams".format(service_name))
  return

def validate_bindings(args):
  bindings = read_bindings(args.bindings)
  for file in args.srcs:
    check_file_exists(file)
    check_fuzzer_exists(file, bindings)
  return

def get_args():
  parser =  argparse.ArgumentParser(description="Tool to check if fuzzer is "
                                                "added for new services")
  parser.add_argument('-b', help='Path to json file containing '
                                 '"service":[fuzzers...] bindings.',
                      required=True, dest='bindings')
  parser.add_argument('-s', '--list', nargs='+',
                      help='list of service_contexts files. Tool will check if '
                           'there is fuzzer for every service in the context '
                           'file.', required=True, dest='srcs')
  parsed_args = parser.parse_args()
  return parsed_args

if __name__ == "__main__":
  args = get_args()
  validate_bindings(args)
