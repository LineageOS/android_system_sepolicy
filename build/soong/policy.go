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
	android.RegisterModuleType("se_policy_cil", policyCilFactory)
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

type policyCilProperties struct {
	// Name of the output. Default is {module_name}
	Stem *string

	// Policy file to be compiled to cil file.
	Src *string `android:"path"`

	// Additional cil files to be added in the end of the output. This is to support workarounds
	// which are not supported by the policy language.
	Additional_cil_files []string `android:"path"`

	// Cil files to be filtered out by the filter_out tool of "build_sepolicy". Used to build
	// exported policies
	Filter_out []string `android:"path"`

	// Whether to remove line markers (denoted by ;;) out of compiled cil files. Defaults to false
	Remove_line_marker *bool

	// Whether to run secilc to check compiled policy or not. Defaults to true
	Secilc_check *bool

	// Whether to ignore neverallow when running secilc check. Defaults to
	// SELINUX_IGNORE_NEVERALLOWS.
	Ignore_neverallow *bool

	// Whether this module is directly installable to one of the partitions. Default is true
	Installable *bool
}

type policyCil struct {
	android.ModuleBase

	properties policyCilProperties

	installSource android.Path
	installPath   android.InstallPath
}

// se_policy_cil compiles a policy.conf file to a cil file with checkpolicy, and optionally runs
// secilc to check the output cil file. Affected by SELINUX_IGNORE_NEVERALLOWS.
func policyCilFactory() android.Module {
	c := &policyCil{}
	c.AddProperties(&c.properties)
	android.InitAndroidArchModule(c, android.DeviceSupported, android.MultilibCommon)
	return c
}

func (c *policyCil) Installable() bool {
	return proptools.BoolDefault(c.properties.Installable, true)
}

func (c *policyCil) stem() string {
	return proptools.StringDefault(c.properties.Stem, c.Name())
}

func (c *policyCil) compileConfToCil(ctx android.ModuleContext, conf android.Path) android.OutputPath {
	cil := android.PathForModuleOut(ctx, c.stem()).OutputPath
	rule := android.NewRuleBuilder(pctx, ctx)
	rule.Command().BuiltTool("checkpolicy").
		Flag("-C"). // Write CIL
		Flag("-M"). // Enable MLS
		FlagWithArg("-c ", strconv.Itoa(PolicyVers)).
		FlagWithOutput("-o ", cil).
		Input(conf)

	if len(c.properties.Additional_cil_files) > 0 {
		rule.Command().Text("cat").
			Inputs(android.PathsForModuleSrc(ctx, c.properties.Additional_cil_files)).
			Text(">> ").Output(cil)
	}

	if len(c.properties.Filter_out) > 0 {
		rule.Command().BuiltTool("build_sepolicy").
			Text("filter_out").
			Flag("-f").
			Inputs(android.PathsForModuleSrc(ctx, c.properties.Filter_out)).
			FlagWithOutput("-t ", cil)
	}

	if proptools.Bool(c.properties.Remove_line_marker) {
		rule.Command().Text("grep -v").
			Text(proptools.ShellEscape(";;")).
			Text(cil.String()).
			Text(">").
			Text(cil.String() + ".tmp").
			Text("&& mv").
			Text(cil.String() + ".tmp").
			Text(cil.String())
	}

	if proptools.BoolDefault(c.properties.Secilc_check, true) {
		secilcCmd := rule.Command().BuiltTool("secilc").
			Flag("-m").                 // Multiple decls
			FlagWithArg("-M ", "true"). // Enable MLS
			Flag("-G").                 // expand and remove auto generated attributes
			FlagWithArg("-c ", strconv.Itoa(PolicyVers)).
			Inputs(android.PathsForModuleSrc(ctx, c.properties.Filter_out)). // Also add cil files which are filtered out
			Text(cil.String()).
			FlagWithArg("-o ", os.DevNull).
			FlagWithArg("-f ", os.DevNull)

		if proptools.BoolDefault(c.properties.Ignore_neverallow, ctx.Config().SelinuxIgnoreNeverallows()) {
			secilcCmd.Flag("-N")
		}
	}

	rule.Build("cil", "Building cil for "+ctx.ModuleName())
	return cil
}

func (c *policyCil) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	if proptools.String(c.properties.Src) == "" {
		ctx.PropertyErrorf("src", "must be specified")
		return
	}
	conf := android.PathForModuleSrc(ctx, *c.properties.Src)
	cil := c.compileConfToCil(ctx, conf)

	c.installPath = android.PathForModuleInstall(ctx, "etc", "selinux")
	c.installSource = cil
	ctx.InstallFile(c.installPath, c.stem(), c.installSource)

	if !c.Installable() {
		c.SkipInstall()
	}
}

func (c *policyCil) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		OutputFile: android.OptionalPathForPath(c.installSource),
		Class:      "ETC",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetBool("LOCAL_UNINSTALLABLE_MODULE", !c.Installable())
				entries.SetPath("LOCAL_MODULE_PATH", c.installPath.ToMakePath())
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", c.stem())
			},
		},
	}}
}

func (c *policyCil) OutputFiles(tag string) (android.Paths, error) {
	if tag == "" {
		return android.Paths{c.installSource}, nil
	}
	return nil, fmt.Errorf("Unknown tag %q", tag)
}

var _ android.OutputFileProducer = (*policyCil)(nil)
