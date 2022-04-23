// Copyright 2021 The Android Open Source Project
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

	"github.com/google/blueprint/proptools"

	"android/soong/android"
)

var (
	compatTestDepTag = dependencyTag{name: "compat_test"}
)

func init() {
	ctx := android.InitRegistrationContext
	ctx.RegisterModuleType("se_compat_cil", compatCilFactory)
	ctx.RegisterSingletonModuleType("se_compat_test", compatTestFactory)
}

// se_compat_cil collects and installs backwards compatibility cil files.
func compatCilFactory() android.Module {
	c := &compatCil{}
	c.AddProperties(&c.properties)
	android.InitAndroidArchModule(c, android.DeviceSupported, android.MultilibCommon)
	return c
}

type compatCil struct {
	android.ModuleBase
	properties    compatCilProperties
	installSource android.Path
	installPath   android.InstallPath
}

type compatCilProperties struct {
	// List of source files. Can reference se_build_files type modules with the ":module" syntax.
	Srcs []string `android:"path"`

	// Output file name. Defaults to module name if unspecified.
	Stem *string
}

func (c *compatCil) stem() string {
	return proptools.StringDefault(c.properties.Stem, c.Name())
}

func (c *compatCil) expandSeSources(ctx android.ModuleContext) android.Paths {
	return android.PathsForModuleSrc(ctx, c.properties.Srcs)
}

func (c *compatCil) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	if c.ProductSpecific() || c.SocSpecific() || c.DeviceSpecific() {
		ctx.ModuleErrorf("Compat cil files only support system and system_ext partitions")
	}

	srcPaths := c.expandSeSources(ctx)
	out := android.PathForModuleGen(ctx, c.Name())
	ctx.Build(pctx, android.BuildParams{
		Rule:        android.Cat,
		Inputs:      srcPaths,
		Output:      out,
		Description: "Combining compat cil for " + c.Name(),
	})

	c.installPath = android.PathForModuleInstall(ctx, "etc", "selinux", "mapping")
	c.installSource = out
	ctx.InstallFile(c.installPath, c.stem(), c.installSource)
}

func (c *compatCil) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class:      "ETC",
		OutputFile: android.OptionalPathForPath(c.installSource),
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetPath("LOCAL_MODULE_PATH", c.installPath)
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", c.stem())
			},
		},
	}}
}

func (c *compatCil) OutputFiles(tag string) (android.Paths, error) {
	switch tag {
	case "":
		return android.Paths{c.installSource}, nil
	default:
		return nil, fmt.Errorf("unsupported module reference tag %q", tag)
	}
}

var _ android.OutputFileProducer = (*compatCil)(nil)

// se_compat_test checks if compat files ({ver}.cil, {ver}.compat.cil) files are compatible with
// current policy.
func compatTestFactory() android.SingletonModule {
	f := &compatTestModule{}
	android.InitAndroidModule(f)
	android.AddLoadHook(f, func(ctx android.LoadHookContext) {
		f.loadHook(ctx)
	})
	return f
}

type compatTestModule struct {
	android.SingletonModuleBase

	compatTestTimestamp android.ModuleOutPath
}

func (f *compatTestModule) createPlatPubVersionedModule(ctx android.LoadHookContext, ver string) {
	confName := fmt.Sprintf("pub_policy_%s.conf", ver)
	cilName := fmt.Sprintf("pub_policy_%s.cil", ver)
	platPubVersionedName := fmt.Sprintf("plat_pub_versioned_%s.cil", ver)

	ctx.CreateModule(policyConfFactory, &nameProperties{
		Name: proptools.StringPtr(confName),
	}, &policyConfProperties{
		Srcs: []string{
			fmt.Sprintf(":se_build_files{.plat_public_%s}", ver),
			fmt.Sprintf(":se_build_files{.system_ext_public_%s}", ver),
			fmt.Sprintf(":se_build_files{.product_public_%s}", ver),
			":se_build_files{.reqd_mask}",
		},
		Installable: proptools.BoolPtr(false),
	})

	ctx.CreateModule(policyCilFactory, &nameProperties{
		Name: proptools.StringPtr(cilName),
	}, &policyCilProperties{
		Src:          proptools.StringPtr(":" + confName),
		Filter_out:   []string{":reqd_policy_mask.cil"},
		Secilc_check: proptools.BoolPtr(false),
		Installable:  proptools.BoolPtr(false),
	})

	ctx.CreateModule(versionedPolicyFactory, &nameProperties{
		Name: proptools.StringPtr(platPubVersionedName),
	}, &versionedPolicyProperties{
		Base:          proptools.StringPtr(":" + cilName),
		Target_policy: proptools.StringPtr(":" + cilName),
		Version:       proptools.StringPtr(ver),
		Installable:   proptools.BoolPtr(false),
	})
}

func (f *compatTestModule) createCompatTestModule(ctx android.LoadHookContext, ver string) {
	srcs := []string{
		":plat_sepolicy.cil",
		":system_ext_sepolicy.cil",
		":product_sepolicy.cil",
		fmt.Sprintf(":plat_%s.cil", ver),
		fmt.Sprintf(":%s.compat.cil", ver),
		fmt.Sprintf(":system_ext_%s.cil", ver),
		fmt.Sprintf(":system_ext_%s.compat.cil", ver),
		fmt.Sprintf(":product_%s.cil", ver),
	}

	if ver == ctx.DeviceConfig().BoardSepolicyVers() {
		srcs = append(srcs,
			":plat_pub_versioned.cil",
			":vendor_sepolicy.cil",
			":odm_sepolicy.cil",
		)
	} else {
		srcs = append(srcs, fmt.Sprintf(":plat_pub_versioned_%s.cil", ver))
	}

	compatTestName := fmt.Sprintf("%s_compat_test", ver)
	ctx.CreateModule(policyBinaryFactory, &nameProperties{
		Name: proptools.StringPtr(compatTestName),
	}, &policyBinaryProperties{
		Srcs:              srcs,
		Ignore_neverallow: proptools.BoolPtr(true),
		Installable:       proptools.BoolPtr(false),
	})
}

func (f *compatTestModule) loadHook(ctx android.LoadHookContext) {
	for _, ver := range ctx.DeviceConfig().PlatformSepolicyCompatVersions() {
		f.createPlatPubVersionedModule(ctx, ver)
		f.createCompatTestModule(ctx, ver)
	}
}

func (f *compatTestModule) DepsMutator(ctx android.BottomUpMutatorContext) {
	for _, ver := range ctx.DeviceConfig().PlatformSepolicyCompatVersions() {
		ctx.AddDependency(f, compatTestDepTag, fmt.Sprintf("%s_compat_test", ver))
	}
}

func (f *compatTestModule) GenerateSingletonBuildActions(ctx android.SingletonContext) {
	// does nothing; se_compat_test is a singeton because two compat test modules don't make sense.
}

func (f *compatTestModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	var inputs android.Paths
	ctx.VisitDirectDepsWithTag(compatTestDepTag, func(child android.Module) {
		o, ok := child.(android.OutputFileProducer)
		if !ok {
			panic(fmt.Errorf("Module %q should be an OutputFileProducer but it isn't", ctx.OtherModuleName(child)))
		}

		outputs, err := o.OutputFiles("")
		if err != nil {
			panic(fmt.Errorf("Module %q error while producing output: %v", ctx.OtherModuleName(child), err))
		}
		if len(outputs) != 1 {
			panic(fmt.Errorf("Module %q should produce exactly one output, but did %q", ctx.OtherModuleName(child), outputs.Strings()))
		}

		inputs = append(inputs, outputs[0])
	})

	f.compatTestTimestamp = android.PathForModuleOut(ctx, "timestamp")
	rule := android.NewRuleBuilder(pctx, ctx)
	rule.Command().Text("touch").Output(f.compatTestTimestamp).Implicits(inputs)
	rule.Build("compat", "compat test timestamp for: "+f.Name())
}

func (f *compatTestModule) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class: "FAKE",
		// OutputFile is needed, even though BUILD_PHONY_PACKAGE doesn't use it.
		// Without OutputFile this module won't be exported to Makefile.
		OutputFile: android.OptionalPathForPath(f.compatTestTimestamp),
		Include:    "$(BUILD_PHONY_PACKAGE)",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetString("LOCAL_ADDITIONAL_DEPENDENCIES", f.compatTestTimestamp.String())
			},
		},
	}}
}
