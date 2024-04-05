// Copyright (C) 2018 The Android Open Source Project
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

// This file contains "se_cil_compat_map" module type used to build and install
// sepolicy backwards compatibility mapping files.

import (
	"android/soong/android"
	"fmt"

	"github.com/google/blueprint"
	"github.com/google/blueprint/proptools"
)

var (
	combine_maps    = pctx.HostBinToolVariable("combine_maps", "combine_maps")
	combineMapsCmd  = "${combine_maps} -t ${topHalf} -b ${bottomHalf} -o $out"
	combineMapsRule = pctx.StaticRule(
		"combineMapsRule",
		blueprint.RuleParams{
			Command:     combineMapsCmd,
			CommandDeps: []string{"${combine_maps}"},
		},
		"topHalf",
		"bottomHalf",
	)

	String        = proptools.String
	TopHalfDepTag = dependencyTag{name: "top"}
)

func init() {
	android.RegisterModuleType("se_cil_compat_map", cilCompatMapFactory)
	pctx.Import("android/soong/android")
}

func cilCompatMapFactory() android.Module {
	c := &cilCompatMap{}
	c.AddProperties(&c.properties)
	android.InitAndroidArchModule(c, android.DeviceSupported, android.MultilibCommon)
	return c
}

type cilCompatMapProperties struct {
	// se_cil_compat_map module representing a compatibility mapping file for
	// platform versions (x->y). Bottom half represents a mapping (y->z).
	// Together the halves are used to generate a (x->z) mapping.
	Top_half *string `android:"path"`
	// list of source (.cil) files used to build an the bottom half of sepolicy
	// compatibility mapping file. bottom_half may reference the outputs of
	// other modules that produce source files like genrule or filegroup using
	// the syntax ":module". srcs has to be non-empty.
	Bottom_half []string `android:"path"`
	// name of the output
	Stem *string
	// Target version that this module supports. This module will be ignored if platform sepolicy
	// version is same as this module's version.
	Version *string
}

type cilCompatMap struct {
	android.ModuleBase
	properties cilCompatMapProperties
	// (.intermediate) module output path as installation source.
	installSource android.OptionalPath
	installPath   android.InstallPath
}

type CilCompatMapGenerator interface {
	GeneratedMapFile() android.OptionalPath
}

func expandTopHalf(ctx android.ModuleContext) android.OptionalPath {
	var topHalf android.OptionalPath
	ctx.VisitDirectDeps(func(dep android.Module) {
		depTag := ctx.OtherModuleDependencyTag(dep)
		switch depTag {
		case TopHalfDepTag:
			topHalf = dep.(CilCompatMapGenerator).GeneratedMapFile()
		}
	})
	return topHalf
}

func expandSeSources(ctx android.ModuleContext, srcFiles []string) android.Paths {
	return android.PathsForModuleSrc(ctx, srcFiles)
}

func (c *cilCompatMap) shouldSkipBuild(ctx android.ModuleContext) bool {
	return proptools.String(c.properties.Version) == ctx.DeviceConfig().PlatformSepolicyVersion()
}

func (c *cilCompatMap) stem() string {
	return proptools.StringDefault(c.properties.Stem, c.Name())
}

func (c *cilCompatMap) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	if c.shouldSkipBuild(ctx) {
		return
	}

	c.installPath = android.PathForModuleInstall(ctx, "etc", "selinux", "mapping")

	srcFiles := expandSeSources(ctx, c.properties.Bottom_half)

	for _, src := range srcFiles {
		if src.Ext() != ".cil" {
			ctx.PropertyErrorf("bottom_half", "%s has to be a .cil file.", src.String())
		}
	}

	bottomHalf := android.PathForModuleGen(ctx, "bottom_half")
	ctx.Build(pctx, android.BuildParams{
		Rule:   android.Cat,
		Output: bottomHalf,
		Inputs: srcFiles,
	})

	topHalf := expandTopHalf(ctx)
	if topHalf.Valid() {
		out := android.PathForModuleGen(ctx, c.Name())
		ctx.ModuleBuild(pctx, android.ModuleBuildParams{
			Rule:   combineMapsRule,
			Output: out,
			Implicits: []android.Path{
				topHalf.Path(),
				bottomHalf,
			},
			Args: map[string]string{
				"topHalf":    topHalf.String(),
				"bottomHalf": bottomHalf.String(),
			},
		})
		c.installSource = android.OptionalPathForPath(out)
	} else {
		c.installSource = android.OptionalPathForPath(bottomHalf)
	}
	ctx.InstallFile(c.installPath, c.stem(), c.installSource.Path())
}

func (c *cilCompatMap) DepsMutator(ctx android.BottomUpMutatorContext) {
	if c.properties.Top_half != nil {
		ctx.AddDependency(c, TopHalfDepTag, String(c.properties.Top_half))
	}
}

func (c *cilCompatMap) AndroidMkEntries() []android.AndroidMkEntries {
	if !c.installSource.Valid() {
		return nil
	}
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class:      "ETC",
		OutputFile: c.installSource,
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetPath("LOCAL_MODULE_PATH", c.installPath)
				if c.properties.Stem != nil {
					entries.SetString("LOCAL_INSTALLED_MODULE_STEM", String(c.properties.Stem))
				}
			},
		},
	}}
}

var _ CilCompatMapGenerator = (*cilCompatMap)(nil)
var _ android.OutputFileProducer = (*cilCompatMap)(nil)

func (c *cilCompatMap) GeneratedMapFile() android.OptionalPath {
	return c.installSource
}

func (c *cilCompatMap) OutputFiles(tag string) (android.Paths, error) {
	if tag == "" {
		if c.installSource.Valid() {
			return android.Paths{c.installSource.Path()}, nil
		} else {
			return nil, nil
		}
	}
	return nil, fmt.Errorf("Unknown tag %q", tag)
}
