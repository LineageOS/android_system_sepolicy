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
	"maps"

	"android/soong/android"

	"github.com/google/blueprint"
)

var (
	flagsDepTag      = dependencyTag{name: "flags"}
	buildFlagsDepTag = dependencyTag{name: "build_flags"}
)

func init() {
	ctx := android.InitRegistrationContext
	ctx.RegisterModuleType("se_flags", flagsFactory)
	ctx.RegisterModuleType("se_flags_collector", flagsCollectorFactory)
}

type flagsProperties struct {
	// List of build time flags for flag-guarding.
	Flags []string

	// List of se_flags_collector modules to export flags to.
	Export_to []string
}

type flagsModule struct {
	android.ModuleBase
	properties flagsProperties
}

type flagsInfo struct {
	Flags []string
}

var flagsProviderKey = blueprint.NewProvider[flagsInfo]()

// se_flags contains a list of build time flags for sepolicy.  Build time flags are defined under
// .scl files (e.g. build/release/build_flags.scl). By importing flags with se_flags modules,
// sepolicy rules can be guarded by `is_flag_enabled` / `is_flag_disabled` macro.
//
// For example, an Android.bp file could have:
//
//	se_flags {
//		name: "aosp_selinux_flags",
//		flags: ["RELEASE_AVF_ENABLE_DEVICE_ASSIGNMENT"],
//		export_to: ["all_selinux_flags"],
//	}
//
// And then one could flag-guard .te file rules:
//
//	is_flag_enabled(RELEASE_AVF_ENABLE_DEVICE_ASSIGNMENT, `
//		type vfio_handler, domain, coredomain;
//		binder_use(vfio_handler)
//	')
//
// or contexts entries:
//
//	is_flag_enabled(RELEASE_AVF_ENABLE_DEVICE_ASSIGNMENT, `
//		android.system.virtualizationservice_internal.IVfioHandler u:object_r:vfio_handler_service:s0
//	')
func flagsFactory() android.Module {
	module := &flagsModule{}
	module.AddProperties(&module.properties)
	android.InitAndroidModule(module)
	return module
}

func (f *flagsModule) DepsMutator(ctx android.BottomUpMutatorContext) {
	// dep se_flag_collector -> se_flags
	for _, export := range f.properties.Export_to {
		ctx.AddReverseDependency(ctx.Module(), flagsDepTag, export)
	}
}

func (f *flagsModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	android.SetProvider(ctx, flagsProviderKey, flagsInfo{
		Flags: f.properties.Flags,
	})
}

type buildFlagsInfo struct {
	BuildFlags map[string]string
}

var buildFlagsProviderKey = blueprint.NewProvider[buildFlagsInfo]()

type flagsCollectorModule struct {
	android.ModuleBase
	buildFlags map[string]string
}

// se_flags_collector module collects flags from exported se_flags modules (see export_to property
// of se_flags modules), and then converts them into build-time flags.  It will be used to generate
// M4 macros to flag-guard sepolicy.
func flagsCollectorFactory() android.Module {
	module := &flagsCollectorModule{}
	android.InitAndroidModule(module)
	return module
}

func (f *flagsCollectorModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	var flags []string
	ctx.VisitDirectDepsWithTag(flagsDepTag, func(m android.Module) {
		if dep, ok := android.OtherModuleProvider(ctx, m, flagsProviderKey); ok {
			flags = append(flags, dep.Flags...)
		} else {
			ctx.ModuleErrorf("unknown dependency %q", ctx.OtherModuleName(m))
		}
	})
	buildFlags := make(map[string]string)
	for _, flag := range android.SortedUniqueStrings(flags) {
		if val, ok := ctx.Config().GetBuildFlag(flag); ok {
			buildFlags[flag] = val
		}
	}
	android.SetProvider(ctx, buildFlagsProviderKey, buildFlagsInfo{
		BuildFlags: buildFlags,
	})
}

type flaggableModuleProperties struct {
	// List of se_flag_collector modules to be passed to M4 macro.
	Build_flags []string
}

type flaggableModule interface {
	android.Module
	flagModuleBase() *flaggableModuleBase
	flagDeps(ctx android.BottomUpMutatorContext)
	getBuildFlags(ctx android.ModuleContext) map[string]string
}

type flaggableModuleBase struct {
	properties flaggableModuleProperties
}

func initFlaggableModule(m flaggableModule) {
	base := m.flagModuleBase()
	m.AddProperties(&base.properties)
}

func (f *flaggableModuleBase) flagModuleBase() *flaggableModuleBase {
	return f
}

func (f *flaggableModuleBase) flagDeps(ctx android.BottomUpMutatorContext) {
	ctx.AddDependency(ctx.Module(), buildFlagsDepTag, f.properties.Build_flags...)
}

// getBuildFlags returns a map from flag names to flag values.
func (f *flaggableModuleBase) getBuildFlags(ctx android.ModuleContext) map[string]string {
	ret := make(map[string]string)
	ctx.VisitDirectDepsWithTag(buildFlagsDepTag, func(m android.Module) {
		if dep, ok := android.OtherModuleProvider(ctx, m, buildFlagsProviderKey); ok {
			maps.Copy(ret, dep.BuildFlags)
		} else {
			ctx.PropertyErrorf("build_flags", "unknown dependency %q", ctx.OtherModuleName(m))
		}
	})
	return ret
}
