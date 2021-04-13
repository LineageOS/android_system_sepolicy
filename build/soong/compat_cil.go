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
	android.RegisterModuleType("se_compat_cil", compatCilFactory)
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
	// List of source files. Can reference se_filegroup type modules with the ":module" syntax.
	Srcs []string

	// Output file name. Defaults to module name if unspecified.
	Stem *string
}

func (c *compatCil) stem() string {
	return proptools.StringDefault(c.properties.Stem, c.Name())
}

func (c *compatCil) expandSeSources(ctx android.ModuleContext) android.Paths {
	srcPaths := make(android.Paths, 0, len(c.properties.Srcs))
	for _, src := range c.properties.Srcs {
		if m := android.SrcIsModule(src); m != "" {
			module := ctx.GetDirectDepWithTag(m, android.SourceDepTag)
			if module == nil {
				// Error would have been handled by ExtractSourcesDeps
				continue
			}
			if fg, ok := module.(*fileGroup); ok {
				if c.SystemExtSpecific() {
					srcPaths = append(srcPaths, fg.SystemExtPrivateSrcs()...)
				} else {
					srcPaths = append(srcPaths, fg.SystemPrivateSrcs()...)
				}
			} else {
				ctx.PropertyErrorf("srcs", "%q is not an se_filegroup", m)
			}
		} else {
			srcPaths = append(srcPaths, android.PathForModuleSrc(ctx, src))
		}
	}
	return srcPaths
}

func (c *compatCil) DepsMutator(ctx android.BottomUpMutatorContext) {
	android.ExtractSourcesDeps(ctx, c.properties.Srcs)
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
				entries.SetPath("LOCAL_MODULE_PATH", c.installPath.ToMakePath())
				entries.SetString("LOCAL_INSTALLED_MODULE_STEM", c.stem())
			},
		},
	}}
}
