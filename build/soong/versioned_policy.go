// Copyright (C) 2021 The Android Open Source Project
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
	"fmt"
	"os"
	"strconv"

	"github.com/google/blueprint/proptools"

	"android/soong/android"
)

func init() {
	android.RegisterModuleType("se_versioned_policy", versionedPolicyFactory)
}

type versionedPolicyProperties struct {
	// Base cil file for versioning.
	Base *string `android:"path"`

	// Output file name. Defaults to {name} if target_policy is set, {version}.cil if mapping is set
	Stem *string

	// Target sepolicy version. Can be a specific version number (e.g. "30.0" for R) or "current"
	// (PLATFORM_SEPOLICY_VERSION). Defaults to "current"
	Version *string

	// If true, generate mapping file from given base cil file. Cannot be set with target_policy.
	Mapping *bool

	// If given, version target policy file according to base policy. Cannot be set with mapping.
	Target_policy *string `android:"path"`

	// Cil files to be filtered out by the filter_out tool of "build_sepolicy".
	Filter_out []string `android:"path"`

	// Cil files to which this mapping file depends. If specified, secilc checks whether the output
	// file can be merged with specified cil files or not.
	Dependent_cils []string `android:"path"`

	// Whether this module is directly installable to one of the partitions. Default is true
	Installable *bool

	// install to a subdirectory of the default install path for the module
	Relative_install_path *string
}

type versionedPolicy struct {
	android.ModuleBase

	properties versionedPolicyProperties

	installSource android.Path
	installPath   android.InstallPath
}

// se_versioned_policy generates versioned cil file with "version_policy". This can generate either
// mapping file for public plat policies, or associate a target policy file with the version that
// non-platform policy targets.
func versionedPolicyFactory() android.Module {
	m := &versionedPolicy{}
	m.AddProperties(&m.properties)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	return m
}

func (m *versionedPolicy) installable() bool {
	return proptools.BoolDefault(m.properties.Installable, true)
}

func (m *versionedPolicy) DepsMutator(ctx android.BottomUpMutatorContext) {
	// do nothing
}

func (m *versionedPolicy) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	version := proptools.StringDefault(m.properties.Version, "current")
	if version == "current" {
		version = ctx.DeviceConfig().PlatformSepolicyVersion()
	}

	var stem string
	if s := proptools.String(m.properties.Stem); s != "" {
		stem = s
	} else if proptools.Bool(m.properties.Mapping) {
		stem = version + ".cil"
	} else {
		stem = ctx.ModuleName()
	}

	out := android.PathForModuleOut(ctx, stem)
	rule := android.NewRuleBuilder(pctx, ctx)

	if proptools.String(m.properties.Base) == "" {
		ctx.PropertyErrorf("base", "must be specified")
		return
	}

	versionCmd := rule.Command().BuiltTool("version_policy").
		FlagWithInput("-b ", android.PathForModuleSrc(ctx, *m.properties.Base)).
		FlagWithArg("-n ", version).
		FlagWithOutput("-o ", out)

	if proptools.Bool(m.properties.Mapping) && proptools.String(m.properties.Target_policy) != "" {
		ctx.ModuleErrorf("Can't set both mapping and target_policy")
		return
	}

	if proptools.Bool(m.properties.Mapping) {
		versionCmd.Flag("-m")
	} else if target := proptools.String(m.properties.Target_policy); target != "" {
		versionCmd.FlagWithInput("-t ", android.PathForModuleSrc(ctx, target))
	} else {
		ctx.ModuleErrorf("Either mapping or target_policy must be set")
		return
	}

	if len(m.properties.Filter_out) > 0 {
		rule.Command().BuiltTool("build_sepolicy").
			Text("filter_out").
			Flag("-f").
			Inputs(android.PathsForModuleSrc(ctx, m.properties.Filter_out)).
			FlagWithOutput("-t ", out)
	}

	if len(m.properties.Dependent_cils) > 0 {
		rule.Command().BuiltTool("secilc").
			Flag("-m").
			FlagWithArg("-M ", "true").
			Flag("-G").
			Flag("-N").
			FlagWithArg("-c ", strconv.Itoa(PolicyVers)).
			Inputs(android.PathsForModuleSrc(ctx, m.properties.Dependent_cils)).
			Text(out.String()).
			FlagWithArg("-o ", os.DevNull).
			FlagWithArg("-f ", os.DevNull)
	}

	rule.Build("mapping", "Versioning mapping file "+ctx.ModuleName())

	m.installSource = out
	m.installPath = android.PathForModuleInstall(ctx, "etc", "selinux")
	if subdir := proptools.String(m.properties.Relative_install_path); subdir != "" {
		m.installPath = m.installPath.Join(ctx, subdir)
	}
	ctx.InstallFile(m.installPath, m.installSource.Base(), m.installSource)

	if !m.installable() {
		m.SkipInstall()
	}
}

func (m *versionedPolicy) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		OutputFile: android.OptionalPathForPath(m.installSource),
		Class:      "ETC",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetBool("LOCAL_UNINSTALLABLE_MODULE", !m.installable())
				entries.SetPath("LOCAL_MODULE_PATH", m.installPath.ToMakePath())
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", m.installSource.Base())
			},
		},
	}}
}

func (m *versionedPolicy) OutputFiles(tag string) (android.Paths, error) {
	if tag == "" {
		return android.Paths{m.installSource}, nil
	}
	return nil, fmt.Errorf("Unknown tag %q", tag)
}

var _ android.OutputFileProducer = (*policyConf)(nil)
