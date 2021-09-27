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
	"path/filepath"
	"sort"

	"android/soong/android"
)

func init() {
	ctx := android.InitRegistrationContext
	ctx.RegisterSingletonModuleType("se_freeze_test", freezeTestFactory)
}

// se_freeze_test compares the plat sepolicy with the prebuilt sepolicy.  Additional directories can
// be specified via Makefile variables: SEPOLICY_FREEZE_TEST_EXTRA_DIRS and
// SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS.
func freezeTestFactory() android.SingletonModule {
	f := &freezeTestModule{}
	android.InitAndroidModule(f)
	return f
}

type freezeTestModule struct {
	android.SingletonModuleBase
	freezeTestTimestamp android.ModuleOutPath
}

func (f *freezeTestModule) GenerateSingletonBuildActions(ctx android.SingletonContext) {
	// does nothing; se_freeze_test is a singeton because two freeze test modules don't make sense.
}

func (f *freezeTestModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	platformVersion := ctx.DeviceConfig().PlatformSepolicyVersion()
	totVersion := ctx.DeviceConfig().TotSepolicyVersion()

	extraDirs := ctx.DeviceConfig().SepolicyFreezeTestExtraDirs()
	extraPrebuiltDirs := ctx.DeviceConfig().SepolicyFreezeTestExtraPrebuiltDirs()
	f.freezeTestTimestamp = android.PathForModuleOut(ctx, "freeze_test")

	if platformVersion == totVersion {
		if len(extraDirs) > 0 || len(extraPrebuiltDirs) > 0 {
			ctx.ModuleErrorf("SEPOLICY_FREEZE_TEST_EXTRA_DIRS or SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS cannot be set before system/sepolicy freezes.")
			return
		}

		// we still build a rule to prevent possible regression
		android.WriteFileRule(ctx, f.freezeTestTimestamp, ";; no freeze tests needed before system/sepolicy freezes")
		return
	}

	if len(extraDirs) != len(extraPrebuiltDirs) {
		ctx.ModuleErrorf("SEPOLICY_FREEZE_TEST_EXTRA_DIRS and SEPOLICY_FREEZE_TEST_EXTRA_PREBUILT_DIRS must have the same number of directories.")
		return
	}

	platPublic := filepath.Join(ctx.ModuleDir(), "public")
	platPrivate := filepath.Join(ctx.ModuleDir(), "private")
	prebuiltPublic := filepath.Join(ctx.ModuleDir(), "prebuilts", "api", platformVersion, "public")
	prebuiltPrivate := filepath.Join(ctx.ModuleDir(), "prebuilts", "api", platformVersion, "private")

	sourceDirs := append(extraDirs, platPublic, platPrivate)
	prebuiltDirs := append(extraPrebuiltDirs, prebuiltPublic, prebuiltPrivate)

	var implicits []string
	for _, dir := range append(sourceDirs, prebuiltDirs...) {
		glob, err := ctx.GlobWithDeps(dir+"/**/*", []string{"bug_map"} /* exclude */)
		if err != nil {
			ctx.ModuleErrorf("failed to glob sepolicy dir %q: %s", dir, err.Error())
			return
		}
		implicits = append(implicits, glob...)
	}
	sort.Strings(implicits)

	rule := android.NewRuleBuilder(pctx, ctx)

	for idx, _ := range sourceDirs {
		rule.Command().Text("diff").
			Flag("-r").
			Flag("-q").
			FlagWithArg("-x ", "bug_map"). // exclude
			Text(sourceDirs[idx]).
			Text(prebuiltDirs[idx])
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
