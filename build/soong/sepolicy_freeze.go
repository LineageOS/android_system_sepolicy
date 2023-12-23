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
	"sort"

	"android/soong/android"
)

var currentCilTag = dependencyTag{name: "current_cil"}
var prebuiltCilTag = dependencyTag{name: "prebuilt_cil"}

func init() {
	ctx := android.InitRegistrationContext
	ctx.RegisterParallelSingletonModuleType("se_freeze_test", freezeTestFactory)
}

// se_freeze_test compares the plat sepolicy with the prebuilt sepolicy.  Additional directories can
// be specified via Makefile variables: SEPOLICY_FREEZE_TEST_EXTRA_DIRS and
// SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS.
func freezeTestFactory() android.SingletonModule {
	f := &freezeTestModule{}
	android.InitAndroidModule(f)
	android.AddLoadHook(f, func(ctx android.LoadHookContext) {
		f.loadHook(ctx)
	})
	return f
}

type freezeTestModule struct {
	android.SingletonModuleBase
	freezeTestTimestamp android.ModuleOutPath
}

func (f *freezeTestModule) shouldRunTest(ctx android.EarlyModuleContext) bool {
	val, _ := ctx.Config().GetBuildFlag("RELEASE_BOARD_API_LEVEL_FROZEN")
	return val == "true"
}

func (f *freezeTestModule) loadHook(ctx android.LoadHookContext) {
	extraDirs := ctx.DeviceConfig().SepolicyFreezeTestExtraDirs()
	extraPrebuiltDirs := ctx.DeviceConfig().SepolicyFreezeTestExtraPrebuiltDirs()

	if !f.shouldRunTest(ctx) {
		if len(extraDirs) > 0 || len(extraPrebuiltDirs) > 0 {
			ctx.ModuleErrorf("SEPOLICY_FREEZE_TEST_EXTRA_DIRS or SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS cannot be set before system/sepolicy freezes.")
			return
		}

		return
	}

	if len(extraDirs) != len(extraPrebuiltDirs) {
		ctx.ModuleErrorf("SEPOLICY_FREEZE_TEST_EXTRA_DIRS and SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS must have the same number of directories.")
		return
	}
}

func (f *freezeTestModule) prebuiltCilModuleName(ctx android.EarlyModuleContext) string {
	return ctx.DeviceConfig().PlatformSepolicyVersion() + "_plat_pub_policy.cil"
}

func (f *freezeTestModule) DepsMutator(ctx android.BottomUpMutatorContext) {
	if !f.shouldRunTest(ctx) {
		return
	}

	ctx.AddDependency(f, currentCilTag, "base_plat_pub_policy.cil")
	ctx.AddDependency(f, prebuiltCilTag, f.prebuiltCilModuleName(ctx))
}

func (f *freezeTestModule) GenerateSingletonBuildActions(ctx android.SingletonContext) {
	// does nothing; se_freeze_test is a singeton because two freeze test modules don't make sense.
}

func (f *freezeTestModule) outputFileOfDep(ctx android.ModuleContext, depTag dependencyTag) android.Path {
	deps := ctx.GetDirectDepsWithTag(depTag)
	if len(deps) != 1 {
		ctx.ModuleErrorf("%d deps having tag %q; expected only one dep", len(deps), depTag)
		return nil
	}

	dep := deps[0]
	outputFileProducer, ok := dep.(android.OutputFileProducer)
	if !ok {
		ctx.ModuleErrorf("module %q is not an output file producer", dep.String())
		return nil
	}

	output, err := outputFileProducer.OutputFiles("")
	if err != nil {
		ctx.ModuleErrorf("module %q failed to produce output: %w", dep.String(), err)
		return nil
	}
	if len(output) != 1 {
		ctx.ModuleErrorf("module %q produced %d outputs; expected only one output", dep.String(), len(output))
		return nil
	}

	return output[0]
}

func (f *freezeTestModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	f.freezeTestTimestamp = android.PathForModuleOut(ctx, "freeze_test")

	if !f.shouldRunTest(ctx) {
		// we still build a rule to prevent possible regression
		android.WriteFileRule(ctx, f.freezeTestTimestamp, ";; no freeze tests needed before system/sepolicy freezes")
		return
	}

	// Freeze test 1: compare ToT sepolicy and prebuilt sepolicy
	currentCil := f.outputFileOfDep(ctx, currentCilTag)
	prebuiltCil := f.outputFileOfDep(ctx, prebuiltCilTag)
	if ctx.Failed() {
		return
	}

	rule := android.NewRuleBuilder(pctx, ctx)
	rule.Command().BuiltTool("sepolicy_freeze_test").
		FlagWithInput("-c ", currentCil).
		FlagWithInput("-p ", prebuiltCil)

	// Freeze test 2: compare extra directories
	// We don't know the exact structure of extra directories, so just directly compare them
	extraDirs := ctx.DeviceConfig().SepolicyFreezeTestExtraDirs()
	extraPrebuiltDirs := ctx.DeviceConfig().SepolicyFreezeTestExtraPrebuiltDirs()

	var implicits []string
	for _, dir := range append(extraDirs, extraPrebuiltDirs...) {
		glob, err := ctx.GlobWithDeps(dir+"/**/*", []string{"bug_map"} /* exclude */)
		if err != nil {
			ctx.ModuleErrorf("failed to glob sepolicy dir %q: %s", dir, err.Error())
			return
		}
		implicits = append(implicits, glob...)
	}
	sort.Strings(implicits)

	for idx, _ := range extraDirs {
		rule.Command().Text("diff").
			Flag("-r").
			Flag("-q").
			FlagWithArg("-x ", "bug_map"). // exclude
			Text(extraDirs[idx]).
			Text(extraPrebuiltDirs[idx])
	}

	rule.Command().Text("touch").
		Output(f.freezeTestTimestamp).
		Implicits(android.PathsForSource(ctx, implicits))

	rule.Build("sepolicy_freeze_test", "sepolicy_freeze_test")
}

func (f *freezeTestModule) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class: "FAKE",
		// OutputFile is needed, even though BUILD_PHONY_PACKAGE doesn't use it.
		// Without OutputFile this module won't be exported to Makefile.
		OutputFile: android.OptionalPathForPath(f.freezeTestTimestamp),
		Include:    "$(BUILD_PHONY_PACKAGE)",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetString("LOCAL_ADDITIONAL_DEPENDENCIES", f.freezeTestTimestamp.String())
			},
		},
	}}
}
