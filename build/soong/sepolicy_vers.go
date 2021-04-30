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

func init() {
	android.RegisterModuleType("sepolicy_vers", sepolicyVersFactory)
}

// sepolicy_vers prints sepolicy version string to {partition}/etc/selinux.
func sepolicyVersFactory() android.Module {
	v := &sepolicyVers{}
	v.AddProperties(&v.properties)
	android.InitAndroidArchModule(v, android.DeviceSupported, android.MultilibCommon)
	return v
}

type sepolicyVers struct {
	android.ModuleBase
	properties    sepolicyVersProperties
	installSource android.Path
	installPath   android.InstallPath
}

type sepolicyVersProperties struct {
	// Version to output. Can be "platform" for PLATFORM_SEPOLICY_VERSION, "vendor" for
	// BOARD_SEPOLICY_VERS
	Version *string

	// Output file name. Defaults to module name if unspecified.
	Stem *string

	// Whether this module is directly installable to one of the partitions. Default is true
	Installable *bool
}

func (v *sepolicyVers) installable() bool {
	return proptools.BoolDefault(v.properties.Installable, true)
}

func (v *sepolicyVers) stem() string {
	return proptools.StringDefault(v.properties.Stem, v.Name())
}

func (v *sepolicyVers) DepsMutator(ctx android.BottomUpMutatorContext) {
	// do nothing
}

func (v *sepolicyVers) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	var ver string
	switch proptools.String(v.properties.Version) {
	case "platform":
		ver = ctx.DeviceConfig().PlatformSepolicyVersion()
	case "vendor":
		ver = ctx.DeviceConfig().BoardSepolicyVers()
	default:
		ctx.PropertyErrorf("version", `should be either "platform" or "vendor"`)
	}

	out := android.PathForModuleGen(ctx, v.stem())

	rule := android.NewRuleBuilder(pctx, ctx)
	rule.Command().Text("echo").Text(ver).Text(">").Output(out)
	rule.Build("sepolicy_vers", v.Name())

	v.installPath = android.PathForModuleInstall(ctx, "etc", "selinux")
	v.installSource = out
	ctx.InstallFile(v.installPath, v.stem(), v.installSource)

	if !v.installable() {
		v.SkipInstall()
	}
}

func (v *sepolicyVers) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class:      "ETC",
		OutputFile: android.OptionalPathForPath(v.installSource),
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetPath("LOCAL_MODULE_PATH", v.installPath.ToMakePath())
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", v.stem())
			},
		},
	}}
}

func (v *sepolicyVers) OutputFiles(tag string) (android.Paths, error) {
	if tag == "" {
		return android.Paths{v.installSource}, nil
	}
	return nil, fmt.Errorf("Unknown tag %q", tag)
}

var _ android.OutputFileProducer = (*sepolicyVers)(nil)
