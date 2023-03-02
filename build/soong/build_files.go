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
	"strings"

	"android/soong/android"
)

func init() {
	android.RegisterModuleType("se_build_files", buildFilesFactory)
}

// se_build_files gathers policy files from sepolicy dirs, and acts like a filegroup. A tag with
// partition(plat, system_ext, product) and scope(public, private) is used to select directories.
// Supported tags are: "plat_public", "plat_private", "system_ext_public", "system_ext_private",
// "product_public", "product_private", and "reqd_mask".
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

	return nil, fmt.Errorf("unknown tag %q. Supported tags are: %q", tag, strings.Join(android.SortedKeys(b.srcs), " "))
}

var _ android.OutputFileProducer = (*buildFiles)(nil)

type sepolicyDir struct {
	tag   string
	paths []string
}

func (b *buildFiles) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	b.srcs = make(map[string]android.Paths)
	b.srcs[".reqd_mask"] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "reqd_mask"))
	b.srcs[".plat_public"] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "public"))
	b.srcs[".plat_private"] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "private"))
	b.srcs[".plat_vendor"] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "vendor"))
	b.srcs[".system_ext_public"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().SystemExtPublicSepolicyDirs()...)
	b.srcs[".system_ext_private"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().SystemExtPrivateSepolicyDirs()...)
	b.srcs[".product_public"] = b.findSrcsInDirs(ctx, ctx.Config().ProductPublicSepolicyDirs()...)
	b.srcs[".product_private"] = b.findSrcsInDirs(ctx, ctx.Config().ProductPrivateSepolicyDirs()...)
	b.srcs[".vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().VendorSepolicyDirs()...)
	b.srcs[".odm"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().OdmSepolicyDirs()...)

	if ctx.DeviceConfig().PlatformSepolicyVersion() == ctx.DeviceConfig().BoardSepolicyVers() {
		// vendor uses the same source with plat policy
		b.srcs[".reqd_mask_for_vendor"] = b.srcs[".reqd_mask"]
		b.srcs[".plat_vendor_for_vendor"] = b.srcs[".plat_vendor"]
		b.srcs[".plat_public_for_vendor"] = b.srcs[".plat_public"]
		b.srcs[".plat_private_for_vendor"] = b.srcs[".plat_private"]
		b.srcs[".system_ext_public_for_vendor"] = b.srcs[".system_ext_public"]
		b.srcs[".system_ext_private_for_vendor"] = b.srcs[".system_ext_private"]
		b.srcs[".product_public_for_vendor"] = b.srcs[".product_public"]
		b.srcs[".product_private_for_vendor"] = b.srcs[".product_private"]
	} else {
		// use vendor-supplied plat prebuilts
		b.srcs[".reqd_mask_for_vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().BoardReqdMaskPolicy()...)
		b.srcs[".plat_vendor_for_vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().BoardPlatVendorPolicy()...)
		b.srcs[".plat_public_for_vendor"] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "prebuilts", "api", ctx.DeviceConfig().BoardSepolicyVers(), "public"))
		b.srcs[".plat_private_for_vendor"] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "prebuilts", "api", ctx.DeviceConfig().BoardSepolicyVers(), "private"))
		b.srcs[".system_ext_public_for_vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().BoardSystemExtPublicPrebuiltDirs()...)
		b.srcs[".system_ext_private_for_vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().BoardSystemExtPrivatePrebuiltDirs()...)
		b.srcs[".product_public_for_vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().BoardProductPublicPrebuiltDirs()...)
		b.srcs[".product_private_for_vendor"] = b.findSrcsInDirs(ctx, ctx.DeviceConfig().BoardProductPrivatePrebuiltDirs()...)
	}

	// directories used for compat tests and Treble tests
	for _, ver := range ctx.DeviceConfig().PlatformSepolicyCompatVersions() {
		b.srcs[".plat_public_"+ver] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "prebuilts", "api", ver, "public"))
		b.srcs[".plat_private_"+ver] = b.findSrcsInDirs(ctx, filepath.Join("system", "sepolicy", "prebuilts", "api", ver, "private"))
		b.srcs[".system_ext_public_"+ver] = b.findSrcsInDirs(ctx, filepath.Join(ctx.DeviceConfig().SystemExtSepolicyPrebuiltApiDir(), "prebuilts", "api", ver, "public"))
		b.srcs[".system_ext_private_"+ver] = b.findSrcsInDirs(ctx, filepath.Join(ctx.DeviceConfig().SystemExtSepolicyPrebuiltApiDir(), "prebuilts", "api", ver, "private"))
		b.srcs[".product_public_"+ver] = b.findSrcsInDirs(ctx, filepath.Join(ctx.DeviceConfig().ProductSepolicyPrebuiltApiDir(), "prebuilts", "api", ver, "public"))
		b.srcs[".product_private_"+ver] = b.findSrcsInDirs(ctx, filepath.Join(ctx.DeviceConfig().ProductSepolicyPrebuiltApiDir(), "prebuilts", "api", ver, "private"))
	}
}
