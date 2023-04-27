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
	"github.com/google/blueprint/proptools"

	"fmt"
	"strconv"

	"android/soong/android"
)

func init() {
	ctx := android.InitRegistrationContext
	ctx.RegisterModuleType("se_neverallow_test", neverallowTestFactory)
}

type neverallowTestProperties struct {
	// Policy files to be tested.
	Srcs []string `android:"path"`
}

type neverallowTestModule struct {
	android.ModuleBase
	properties    neverallowTestProperties
	testTimestamp android.OutputPath
}

type nameProperties struct {
	Name *string
}

var checkpolicyTag = dependencyTag{name: "checkpolicy"}
var sepolicyAnalyzeTag = dependencyTag{name: "sepolicy_analyze"}

// se_neverallow_test builds given policy files and checks whether any neverallow violations exist.
// This module creates two conf files, one with build test and one without build test. Policy with
// build test will be compiled with checkpolicy, and policy without build test will be tested with
// sepolicy-analyze's neverallow tool.  This module's check can be skipped by setting
// SELINUX_IGNORE_NEVERALLOWS := true.
func neverallowTestFactory() android.Module {
	n := &neverallowTestModule{}
	n.AddProperties(&n.properties)
	android.InitAndroidModule(n)
	android.AddLoadHook(n, func(ctx android.LoadHookContext) {
		n.loadHook(ctx)
	})
	return n
}

// Child conf module name for checkpolicy test.
func (n *neverallowTestModule) checkpolicyConfModuleName() string {
	return n.Name() + ".checkpolicy.conf"
}

// Child conf module name for sepolicy-analyze test.
func (n *neverallowTestModule) sepolicyAnalyzeConfModuleName() string {
	return n.Name() + ".sepolicy_analyze.conf"
}

func (n *neverallowTestModule) loadHook(ctx android.LoadHookContext) {
	checkpolicyConf := n.checkpolicyConfModuleName()
	ctx.CreateModule(policyConfFactory, &nameProperties{
		Name: proptools.StringPtr(checkpolicyConf),
	}, &policyConfProperties{
		Srcs:          n.properties.Srcs,
		Build_variant: proptools.StringPtr("user"),
		Installable:   proptools.BoolPtr(false),
	})

	sepolicyAnalyzeConf := n.sepolicyAnalyzeConfModuleName()
	ctx.CreateModule(policyConfFactory, &nameProperties{
		Name: proptools.StringPtr(sepolicyAnalyzeConf),
	}, &policyConfProperties{
		Srcs:               n.properties.Srcs,
		Build_variant:      proptools.StringPtr("user"),
		Exclude_build_test: proptools.BoolPtr(true),
		Installable:        proptools.BoolPtr(false),
	})
}

func (n *neverallowTestModule) DepsMutator(ctx android.BottomUpMutatorContext) {
	ctx.AddDependency(n, checkpolicyTag, n.checkpolicyConfModuleName())
	ctx.AddDependency(n, sepolicyAnalyzeTag, n.sepolicyAnalyzeConfModuleName())
}

func (n *neverallowTestModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	n.testTimestamp = pathForModuleOut(ctx, "timestamp")
	if ctx.Config().SelinuxIgnoreNeverallows() {
		// just touch
		android.WriteFileRule(ctx, n.testTimestamp, "")
		return
	}

	var checkpolicyConfPaths android.Paths
	var sepolicyAnalyzeConfPaths android.Paths

	ctx.VisitDirectDeps(func(child android.Module) {
		depTag := ctx.OtherModuleDependencyTag(child)
		if depTag != checkpolicyTag && depTag != sepolicyAnalyzeTag {
			return
		}

		o, ok := child.(android.OutputFileProducer)
		if !ok {
			panic(fmt.Errorf("Module %q isn't an OutputFileProducer", ctx.OtherModuleName(child)))
		}

		outputs, err := o.OutputFiles("")
		if err != nil {
			panic(fmt.Errorf("Module %q error while producing output: %v", ctx.OtherModuleName(child), err))
		}

		switch ctx.OtherModuleDependencyTag(child) {
		case checkpolicyTag:
			checkpolicyConfPaths = outputs
		case sepolicyAnalyzeTag:
			sepolicyAnalyzeConfPaths = outputs
		}
	})

	if len(checkpolicyConfPaths) != 1 {
		panic(fmt.Errorf("Module %q should produce exactly one output", n.checkpolicyConfModuleName()))
	}

	if len(sepolicyAnalyzeConfPaths) != 1 {
		panic(fmt.Errorf("Module %q should produce exactly one output", n.sepolicyAnalyzeConfModuleName()))
	}

	checkpolicyConfPath := checkpolicyConfPaths[0]
	sepolicyAnalyzeConfPath := sepolicyAnalyzeConfPaths[0]

	rule := android.NewRuleBuilder(pctx, ctx)

	// Step 1. Build a binary policy from the conf file including build test
	binaryPolicy := pathForModuleOut(ctx, "policy")
	rule.Command().BuiltTool("checkpolicy").
		Flag("-M").
		FlagWithArg("-c ", strconv.Itoa(PolicyVers)).
		FlagWithOutput("-o ", binaryPolicy).
		Input(checkpolicyConfPath)
	rule.Build("neverallow_checkpolicy", "Neverallow check: "+ctx.ModuleName())

	// Step 2. Run sepolicy-analyze with the conf file without the build test and binary policy
	// file from Step 1
	rule = android.NewRuleBuilder(pctx, ctx)
	msg := `sepolicy-analyze failed. This is most likely due to the use\n` +
		`of an expanded attribute in a neverallow assertion. Please fix\n` +
		`the policy.`

	rule.Command().BuiltTool("sepolicy-analyze").
		Input(binaryPolicy).
		Text("neverallow").
		Flag("-w").
		FlagWithInput("-f ", sepolicyAnalyzeConfPath).
		Text("|| (echo").
		Flag("-e").
		Text(`"` + msg + `"`).
		Text("; exit 1)")

	rule.Command().Text("touch").Output(n.testTimestamp)
	rule.Build("neverallow_sepolicy-analyze", "Neverallow check: "+ctx.ModuleName())
}

func (n *neverallowTestModule) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		OutputFile: android.OptionalPathForPath(n.testTimestamp),
		Class:      "ETC",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetBool("LOCAL_UNINSTALLABLE_MODULE", true)
			},
		},
	}}
}
