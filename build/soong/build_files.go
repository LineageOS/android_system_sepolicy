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
	"path/filepath"
	"sort"
	"strings"

	"android/soong/android"
)

func init() {
	android.RegisterModuleType("se_build_files", buildFilesFactory)
}

// se_build_files gathers policy files from sepolicy dirs, and acts like a filegroup. A tag with
// partition(plat, system_ext, product) and scope(public, private) is used to select directories.
// Supported tags are: "plat", "plat_public", "system_ext", "system_ext_public", "product",
// "product_public", and "reqd_mask".
func buildFilesFactory() android.Module {
	module := &buildFiles{}
	module.AddProperties(&module.properties)
	android.InitAndroidModule(module)
	return module
}

type buildFilesProperties struct {
	// list of source file suffixes used to collect selinux policy files.
	// Source files will be looked up in the following local directories:
	// system/sepolicy/{public, private, vendor, reqd_mask}
	// and directories specified by following config variables:
	// BOARD_SEPOLICY_DIRS, BOARD_ODM_SEPOLICY_DIRS
	// SYSTEM_EXT_PUBLIC_SEPOLICY_DIR, SYSTEM_EXT_PRIVATE_SEPOLICY_DIR
	Srcs []string
}

type buildFiles struct {
	android.ModuleBase
	properties buildFilesProperties

	srcs map[string]android.Paths
}

func (b *buildFiles) findSrcsInDirs(ctx android.ModuleContext, dirs ...string) android.Paths {
	result := android.Paths{}
	for _, file := range b.properties.Srcs {
		for _, dir := range dirs {
			path := filepath.Join(dir, file)
			files, err := ctx.GlobWithDeps(path, nil)
			if err != nil {
				ctx.ModuleErrorf("glob: %s", err.Error())
			}
			for _, f := range files {
				result = append(result, android.PathForSource(ctx, f))
			}
		}
	}
	return result
}

func (b *buildFiles) DepsMutator(ctx android.BottomUpMutatorContext) {
	// do nothing
}

func (b *buildFiles) OutputFiles(tag string) (android.Paths, error) {
	if paths, ok := b.srcs[tag]; ok {
		return paths, nil
	}

	return nil, fmt.Errorf("unknown tag %q. Supported tags are: %q", tag, strings.Join(android.SortedStringKeys(b.srcs), " "))
}

var _ android.OutputFileProducer = (*buildFiles)(nil)

type partition int

const (
	system partition = iota
	system_ext
	product
)

type scope int

const (
	public scope = iota
	private
)

type sepolicyDir struct {
	partition partition
	scope     scope
	paths     []string
}

func (p partition) String() string {
	switch p {
	case system:
		return "plat"
	case system_ext:
		return "system_ext"
	case product:
		return "product"
	default:
		panic(fmt.Sprintf("Unknown partition %#v", p))
	}
}

func (b *buildFiles) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	// Sepolicy directories should be included in the following order.
	//   - system_public
	//   - system_private
	//   - system_ext_public
	//   - system_ext_private
	//   - product_public
	//   - product_private
	dirs := []sepolicyDir{
		sepolicyDir{partition: system, scope: public, paths: []string{filepath.Join(ctx.ModuleDir(), "public")}},
		sepolicyDir{partition: system, scope: private, paths: []string{filepath.Join(ctx.ModuleDir(), "private")}},
		sepolicyDir{partition: system_ext, scope: public, paths: ctx.DeviceConfig().SystemExtPublicSepolicyDirs()},
		sepolicyDir{partition: system_ext, scope: private, paths: ctx.DeviceConfig().SystemExtPrivateSepolicyDirs()},
		sepolicyDir{partition: product, scope: public, paths: ctx.Config().ProductPublicSepolicyDirs()},
		sepolicyDir{partition: product, scope: private, paths: ctx.Config().ProductPrivateSepolicyDirs()},
	}

	if !sort.SliceIsSorted(dirs, func(i, j int) bool {
		if dirs[i].partition != dirs[j].partition {
			return dirs[i].partition < dirs[j].partition
		}

		return dirs[i].scope < dirs[j].scope
	}) {
		panic("dirs is not sorted")
	}

	// Exported cil policy files are built with the following policies.
	//
	//   - plat_pub_policy.cil: exported 'system'
	//   - system_ext_pub_policy.cil: exported 'system' and 'system_ext'
	//   - pub_policy.cil: exported 'system', 'system_ext', and 'product'
	//
	// cil policy files are built with the following policies.
	//
	//   - plat_policy.cil: 'system', including private
	//   - system_ext_policy.cil: 'system_ext', including private
	//   - product_sepolicy.cil: 'product', including private
	//
	// gatherDirsFor collects all needed directories for given partition and scope. For example,
	//
	//   - gatherDirsFor(system_ext, private) will return system + system_ext (including private)
	//   - gatherDirsFor(product, public) will return system + system_ext + product (public only)
	//
	// "dirs" should be sorted before calling this.
	gatherDirsFor := func(p partition, s scope) []string {
		var ret []string

		for _, d := range dirs {
			if d.partition <= p && d.scope <= s {
				ret = append(ret, d.paths...)
			}
		}

		return ret
	}

	reqdMaskDir := filepath.Join(ctx.ModuleDir(), "reqd_mask")

	b.srcs = make(map[string]android.Paths)
	b.srcs[".reqd_mask"] = b.findSrcsInDirs(ctx, reqdMaskDir)

	for _, p := range []partition{system, system_ext, product} {
		b.srcs["."+p.String()] = b.findSrcsInDirs(ctx, gatherDirsFor(p, private)...)

		// reqd_mask is needed for public policies
		b.srcs["."+p.String()+"_public"] = b.findSrcsInDirs(ctx, append(gatherDirsFor(p, public), reqdMaskDir)...)
	}

	// A special tag, "plat_vendor", includes minimized vendor policies required to boot.
	//   - system/sepolicy/public
	//   - system/sepolicy/reqd_mask
	//   - system/sepolicy/vendor
	// This is for minimized vendor partition, e.g. microdroid's vendor
	platVendorDir := filepath.Join(ctx.ModuleDir(), "vendor")
	b.srcs[".plat_vendor"] = b.findSrcsInDirs(ctx, append(gatherDirsFor(system, public), reqdMaskDir, platVendorDir)...)
}
