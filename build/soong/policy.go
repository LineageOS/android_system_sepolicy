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

const (
	// TODO: sync with Android.mk
	MlsSens    = 1
	MlsCats    = 1024
	PolicyVers = 30
)

func init() {
	android.RegisterModuleType("se_policy_conf", policyConfFactory)
}

type policyConfProperties struct {
	// Name of the output. Default is {module_name}
	Stem *string

	// Policy files to be compiled to cil file.
	Srcs []string `android:"path"`

	// Target build variant (user / userdebug / eng). Default follows the current lunch target
	Build_variant *string

	// Whether to exclude build test or not. Default is false
	Exclude_build_test *bool

	// Whether to include asan specific policies or not. Default follows the current lunch target
	With_asan *bool

	// Whether to build CTS specific policy or not. Default is false
	Cts *bool

	// Whether this module is directly installable to one of the partitions. Default is true
	Installable *bool
}

type policyConf struct {
	android.ModuleBase

	properties policyConfProperties

	installSource android.Path
	installPath   android.InstallPath
}

// se_policy_conf merges collection of policy files into a policy.conf file to be processed by
// checkpolicy.
func policyConfFactory() android.Module {
	c := &policyConf{}
	c.AddProperties(&c.properties)
	android.InitAndroidArchModule(c, android.DeviceSupported, android.MultilibCommon)
	return c
}

func (c *policyConf) installable() bool {
	return proptools.BoolDefault(c.properties.Installable, true)
}

func (c *policyConf) stem() string {
	return proptools.StringDefault(c.properties.Stem, c.Name())
}

func (c *policyConf) buildVariant(ctx android.ModuleContext) string {
	if variant := proptools.String(c.properties.Build_variant); variant != "" {
		return variant
	}
	if ctx.Config().Eng() {
		return "eng"
	}
	if ctx.Config().Debuggable() {
		return "userdebug"
	}
	return "user"
}

func (c *policyConf) cts() bool {
	return proptools.Bool(c.properties.Cts)
}

func (c *policyConf) withAsan(ctx android.ModuleContext) string {
	isAsanDevice := android.InList("address", ctx.Config().SanitizeDevice())
	return strconv.FormatBool(proptools.BoolDefault(c.properties.With_asan, isAsanDevice))
}

func (c *policyConf) sepolicySplit(ctx android.ModuleContext) string {
	if c.cts() {
		return "cts"
	}
	return strconv.FormatBool(ctx.DeviceConfig().SepolicySplit())
}

func (c *policyConf) compatibleProperty(ctx android.ModuleContext) string {
	if c.cts() {
		return "cts"
	}
	return "true"
}

func (c *policyConf) trebleSyspropNeverallow(ctx android.ModuleContext) string {
	if c.cts() {
		return "cts"
	}
	return strconv.FormatBool(!ctx.DeviceConfig().BuildBrokenTrebleSyspropNeverallow())
}

func (c *policyConf) enforceSyspropOwner(ctx android.ModuleContext) string {
	if c.cts() {
		return "cts"
	}
	return strconv.FormatBool(!ctx.DeviceConfig().BuildBrokenEnforceSyspropOwner())
}

func (c *policyConf) transformPolicyToConf(ctx android.ModuleContext) android.OutputPath {
	conf := android.PathForModuleOut(ctx, "conf").OutputPath
	rule := android.NewRuleBuilder(pctx, ctx)
	rule.Command().Tool(ctx.Config().PrebuiltBuildTool(ctx, "m4")).
		Flag("--fatal-warnings").
		FlagForEachArg("-D ", ctx.DeviceConfig().SepolicyM4Defs()).
		FlagWithArg("-D mls_num_sens=", strconv.Itoa(MlsSens)).
		FlagWithArg("-D mls_num_cats=", strconv.Itoa(MlsCats)).
		FlagWithArg("-D target_arch=", ctx.DeviceConfig().DeviceArch()).
		FlagWithArg("-D target_with_asan=", c.withAsan(ctx)).
		FlagWithArg("-D target_with_native_coverage=", strconv.FormatBool(ctx.DeviceConfig().ClangCoverageEnabled() || ctx.DeviceConfig().GcovCoverageEnabled())).
		FlagWithArg("-D target_build_variant=", c.buildVariant(ctx)).
		FlagWithArg("-D target_full_treble=", c.sepolicySplit(ctx)).
		FlagWithArg("-D target_compatible_property=", c.compatibleProperty(ctx)).
		FlagWithArg("-D target_treble_sysprop_neverallow=", c.trebleSyspropNeverallow(ctx)).
		FlagWithArg("-D target_enforce_sysprop_owner=", c.enforceSyspropOwner(ctx)).
		FlagWithArg("-D target_exclude_build_test=", strconv.FormatBool(proptools.Bool(c.properties.Exclude_build_test))).
		FlagWithArg("-D target_requires_insecure_execmem_for_swiftshader=", strconv.FormatBool(ctx.DeviceConfig().RequiresInsecureExecmemForSwiftshader())).
		Flag("-s").
		Inputs(android.PathsForModuleSrc(ctx, c.properties.Srcs)).
		Text("> ").Output(conf)

	rule.Build("conf", "Transform policy to conf: "+ctx.ModuleName())
	return conf
}

func (c *policyConf) DepsMutator(ctx android.BottomUpMutatorContext) {
	// do nothing
}

func (c *policyConf) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	c.installSource = c.transformPolicyToConf(ctx)
	c.installPath = android.PathForModuleInstall(ctx, "etc")
	ctx.InstallFile(c.installPath, c.stem(), c.installSource)

	if !c.installable() {
		c.SkipInstall()
	}
}

func (c *policyConf) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		OutputFile: android.OptionalPathForPath(c.installSource),
		Class:      "ETC",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetBool("LOCAL_UNINSTALLABLE_MODULE", !c.installable())
				entries.SetPath("LOCAL_MODULE_PATH", c.installPath.ToMakePath())
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", c.stem())
			},
		},
	}}
}

func (c *policyConf) OutputFiles(tag string) (android.Paths, error) {
	if tag == "" {
		return android.Paths{c.installSource}, nil
	}
	return nil, fmt.Errorf("Unknown tag %q", tag)
}

var _ android.OutputFileProducer = (*policyConf)(nil)
