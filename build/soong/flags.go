// Copyright (C) 2023 The Android Open Source Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package selinux

import (
	"android/soong/android"
)

type flagsProperties struct {
	// List of flags to be passed to M4 macro.
	Flags []string
}

type flaggableModule interface {
	android.Module
	flagModuleBase() *flaggableModuleBase
	getBuildFlags(ctx android.ModuleContext) map[string]string
}

type flaggableModuleBase struct {
	properties flagsProperties
}

func initFlaggableModule(m flaggableModule) {
	base := m.flagModuleBase()
	m.AddProperties(&base.properties)
}

func (f *flaggableModuleBase) flagModuleBase() *flaggableModuleBase {
	return f
}

// getBuildFlags returns a map from flag names to flag values.
func (f *flaggableModuleBase) getBuildFlags(ctx android.ModuleContext) map[string]string {
	ret := make(map[string]string)
	for _, flag := range android.SortedUniqueStrings(f.properties.Flags) {
		if val, ok := ctx.Config().GetBuildFlag(flag); ok {
			ret[flag] = val
		}
	}
	return ret
}
