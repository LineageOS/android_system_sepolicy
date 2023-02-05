#!/bin/bash

# Copyright (C) 2023 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [ $# -ne 1 ]; then
    echo "Usage: $0 <directory>"
    exit 1
fi

directory=$1

# This fixes the Neverallow test involving policy violations of isolated_compute_app
function fix_isolated_policies
{
  # Replace make sure we don't wrongly replace the existing occurrence
  find "$directory" -name "*.te" -print0 | xargs -0 sed -i 's/-\s*isolated_app_all/-isolated_app/g'

  # Replacement
  find "$directory" -name "*.te" -print0 | xargs -0 sed -i 's/-\s*isolated_app/-isolated_app_all/g'

  echo "Successfully replaced all occurrences of '-isolated_app' to '-isolated_app_all'!"
}

fix_isolated_policies
