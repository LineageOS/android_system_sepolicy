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

	"android/soong/android"
)

func init() {
	android.RegisterModuleType("se_bug_map", bugMapFactory)
}

// se_bug_map collects and installs selinux denial bug tracking information to be loaded by auditd.
func bugMapFactory() android.Module {
	c := &bugMap{}
	c.AddProperties(&c.properties)
	android.InitAndroidArchModule(c, android.DeviceSupported, android.MultilibCommon)
	return c
}

type bugMap struct {
	android.ModuleBase
	properties    bugMapProperties
	installSource android.Path
	installPath   android.InstallPath
}

type bugMapProperties struct {
	// List of source files or se_build_files modules.
	Srcs []string `android:"path"`

	// Output file name. Defaults to module name if unspecified.
	Stem *string
}

func (b *bugMap) stem() string {
	return proptools.StringDefault(b.properties.Stem, b.Name())
}

func (b *bugMap) expandSeSources(ctx android.ModuleContext) android.Paths {
	return android.PathsForModuleSrc(ctx, b.properties.Srcs)
}

func (b *bugMap) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	if !b.SocSpecific() && !b.SystemExtSpecific() && !b.Platform() {
		ctx.ModuleErrorf("Selinux bug_map can only be installed in system, system_ext and vendor partitions")
	}

	srcPaths := b.expandSeSources(ctx)
	out := android.PathForModuleGen(ctx, b.Name())
	ctx.Build(pctx, android.BuildParams{
		Rule:        android.Cat,
		Inputs:      srcPaths,
		Output:      out,
		Description: "Combining bug_map for " + b.Name(),
	})

	b.installPath = android.PathForModuleInstall(ctx, "etc", "selinux")
	b.installSource = out
	ctx.InstallFile(b.installPath, b.stem(), b.installSource)
}

func (b *bugMap) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class:      "ETC",
		OutputFile: android.OptionalPathForPath(b.installSource),
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetPath("LOCAL_MODULE_PATH", b.installPath)
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", b.stem())
			},
		},
	}}
}
