// Copyright (C) 2019 The Android Open Source Project
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
	"io"
	"strings"

	"github.com/google/blueprint/proptools"

	"android/soong/android"
)

const (
	coreMode     = "core"
	recoveryMode = "recovery"
)

type selinuxContextsProperties struct {
	// Filenames under sepolicy directories, which will be used to generate contexts file.
	Srcs []string `android:"path"`

	Product_variables struct {
		Debuggable struct {
			Srcs []string
		}

		Address_sanitize struct {
			Srcs []string
		}
	}

	// Whether reqd_mask directory is included to sepolicy directories or not.
	Reqd_mask *bool

	// Whether the comments in generated contexts file will be removed or not.
	Remove_comment *bool

	// Whether the result context file is sorted with fc_sort or not.
	Fc_sort *bool

	// Make this module available when building for recovery
	Recovery_available *bool

	InRecovery bool `blueprint:"mutated"`
}

type fileContextsProperties struct {
	// flatten_apex can be used to specify additional sources of file_contexts.
	// Apex paths, /system/apex/{apex_name}, will be amended to the paths of file_contexts
	// entries.
	Flatten_apex struct {
		Srcs []string
	}
}

type selinuxContextsModule struct {
	android.ModuleBase

	properties             selinuxContextsProperties
	fileContextsProperties fileContextsProperties
	build                  func(ctx android.ModuleContext, inputs android.Paths)
	outputPath             android.ModuleGenPath
	installPath            android.InstallPath
}

var (
	reuseContextsDepTag = dependencyTag{name: "reuseContexts"}
)

func init() {
	pctx.HostBinToolVariable("fc_sort", "fc_sort")

	android.RegisterModuleType("file_contexts", fileFactory)
	android.RegisterModuleType("hwservice_contexts", hwServiceFactory)
	android.RegisterModuleType("property_contexts", propertyFactory)
	android.RegisterModuleType("service_contexts", serviceFactory)

	android.PreDepsMutators(func(ctx android.RegisterMutatorsContext) {
		ctx.BottomUp("selinux_contexts", selinuxContextsMutator).Parallel()
	})
}

func (m *selinuxContextsModule) inRecovery() bool {
	return m.properties.InRecovery || m.ModuleBase.InstallInRecovery()
}

func (m *selinuxContextsModule) onlyInRecovery() bool {
	return m.ModuleBase.InstallInRecovery()
}

func (m *selinuxContextsModule) InstallInRecovery() bool {
	return m.inRecovery()
}

func (m *selinuxContextsModule) InstallInRoot() bool {
	return m.inRecovery()
}

func (m *selinuxContextsModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	if m.inRecovery() {
		// Installing context files at the root of the recovery partition
		m.installPath = android.PathForModuleInstall(ctx)
	} else {
		m.installPath = android.PathForModuleInstall(ctx, "etc", "selinux")
	}

	if m.inRecovery() && !m.onlyInRecovery() {
		dep := ctx.GetDirectDepWithTag(m.Name(), reuseContextsDepTag)

		if reuseDeps, ok := dep.(*selinuxContextsModule); ok {
			m.outputPath = reuseDeps.outputPath
			ctx.InstallFile(m.installPath, m.Name(), m.outputPath)
			return
		}
	}

	var inputs android.Paths

	ctx.VisitDirectDepsWithTag(android.SourceDepTag, func(dep android.Module) {
		segroup, ok := dep.(*fileGroup)
		if !ok {
			ctx.ModuleErrorf("srcs dependency %q is not an selinux filegroup",
				ctx.OtherModuleName(dep))
			return
		}

		if ctx.ProductSpecific() {
			inputs = append(inputs, segroup.ProductPrivateSrcs()...)
		} else if ctx.SocSpecific() {
			inputs = append(inputs, segroup.SystemVendorSrcs()...)
			inputs = append(inputs, segroup.VendorSrcs()...)
		} else if ctx.DeviceSpecific() {
			inputs = append(inputs, segroup.OdmSrcs()...)
		} else if ctx.SystemExtSpecific() {
			inputs = append(inputs, segroup.SystemExtPrivateSrcs()...)
		} else {
			inputs = append(inputs, segroup.SystemPrivateSrcs()...)

			if ctx.Config().ProductCompatibleProperty() {
				inputs = append(inputs, segroup.SystemPublicSrcs()...)
			}
		}

		if proptools.Bool(m.properties.Reqd_mask) {
			inputs = append(inputs, segroup.SystemReqdMaskSrcs()...)
		}
	})

	for _, src := range m.properties.Srcs {
		// Module sources are handled above with VisitDirectDepsWithTag
		if android.SrcIsModule(src) == "" {
			inputs = append(inputs, android.PathForModuleSrc(ctx, src))
		}
	}

	m.build(ctx, inputs)
}

func newModule() *selinuxContextsModule {
	m := &selinuxContextsModule{}
	m.AddProperties(
		&m.properties,
	)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	android.AddLoadHook(m, func(ctx android.LoadHookContext) {
		m.selinuxContextsHook(ctx)
	})
	return m
}

func (m *selinuxContextsModule) selinuxContextsHook(ctx android.LoadHookContext) {
	// TODO: clean this up to use build/soong/android/variable.go after b/79249983
	var srcs []string

	if ctx.Config().Debuggable() {
		srcs = append(srcs, m.properties.Product_variables.Debuggable.Srcs...)
	}

	for _, sanitize := range ctx.Config().SanitizeDevice() {
		if sanitize == "address" {
			srcs = append(srcs, m.properties.Product_variables.Address_sanitize.Srcs...)
			break
		}
	}

	m.properties.Srcs = append(m.properties.Srcs, srcs...)
}

func (m *selinuxContextsModule) AndroidMk() android.AndroidMkData {
	return android.AndroidMkData{
		Custom: func(w io.Writer, name, prefix, moduleDir string, data android.AndroidMkData) {
			nameSuffix := ""
			if m.inRecovery() && !m.onlyInRecovery() {
				nameSuffix = ".recovery"
			}
			fmt.Fprintln(w, "\ninclude $(CLEAR_VARS)")
			fmt.Fprintln(w, "LOCAL_PATH :=", moduleDir)
			fmt.Fprintln(w, "LOCAL_MODULE :=", name+nameSuffix)
			fmt.Fprintln(w, "LOCAL_MODULE_CLASS := ETC")
			if m.Owner() != "" {
				fmt.Fprintln(w, "LOCAL_MODULE_OWNER :=", m.Owner())
			}
			fmt.Fprintln(w, "LOCAL_MODULE_TAGS := optional")
			fmt.Fprintln(w, "LOCAL_PREBUILT_MODULE_FILE :=", m.outputPath.String())
			fmt.Fprintln(w, "LOCAL_MODULE_PATH :=", m.installPath.ToMakePath().String())
			fmt.Fprintln(w, "LOCAL_INSTALLED_MODULE_STEM :=", name)
			fmt.Fprintln(w, "include $(BUILD_PREBUILT)")
		},
	}
}

func selinuxContextsMutator(ctx android.BottomUpMutatorContext) {
	m, ok := ctx.Module().(*selinuxContextsModule)
	if !ok {
		return
	}

	var coreVariantNeeded bool = true
	var recoveryVariantNeeded bool = false
	if proptools.Bool(m.properties.Recovery_available) {
		recoveryVariantNeeded = true
	}

	if m.ModuleBase.InstallInRecovery() {
		recoveryVariantNeeded = true
		coreVariantNeeded = false
	}

	var variants []string
	if coreVariantNeeded {
		variants = append(variants, coreMode)
	}
	if recoveryVariantNeeded {
		variants = append(variants, recoveryMode)
	}
	mod := ctx.CreateVariations(variants...)

	for i, v := range variants {
		if v == recoveryMode {
			m := mod[i].(*selinuxContextsModule)
			m.properties.InRecovery = true

			if coreVariantNeeded {
				ctx.AddInterVariantDependency(reuseContextsDepTag, m, mod[i-1])
			}
		}
	}
}

func (m *selinuxContextsModule) buildGeneralContexts(ctx android.ModuleContext, inputs android.Paths) {
	m.outputPath = android.PathForModuleGen(ctx, ctx.ModuleName()+"_m4out")

	rule := android.NewRuleBuilder()

	rule.Command().
		Tool(ctx.Config().PrebuiltBuildTool(ctx, "m4")).
		Text("--fatal-warnings -s").
		FlagForEachArg("-D", ctx.DeviceConfig().SepolicyM4Defs()).
		Inputs(inputs).
		FlagWithOutput("> ", m.outputPath)

	if proptools.Bool(m.properties.Remove_comment) {
		rule.Temporary(m.outputPath)

		remove_comment_output := android.PathForModuleGen(ctx, ctx.ModuleName()+"_remove_comment")

		rule.Command().
			Text("sed -e 's/#.*$//' -e '/^$/d'").
			Input(m.outputPath).
			FlagWithOutput("> ", remove_comment_output)

		m.outputPath = remove_comment_output
	}

	if proptools.Bool(m.properties.Fc_sort) {
		rule.Temporary(m.outputPath)

		sorted_output := android.PathForModuleGen(ctx, ctx.ModuleName()+"_sorted")

		rule.Command().
			Tool(ctx.Config().HostToolPath(ctx, "fc_sort")).
			FlagWithInput("-i ", m.outputPath).
			FlagWithOutput("-o ", sorted_output)

		m.outputPath = sorted_output
	}

	rule.Build(pctx, ctx, "selinux_contexts", m.Name())

	rule.DeleteTemporaryFiles()

	ctx.InstallFile(m.installPath, ctx.ModuleName(), m.outputPath)
}

func (m *selinuxContextsModule) buildFileContexts(ctx android.ModuleContext, inputs android.Paths) {
	if m.properties.Fc_sort == nil {
		m.properties.Fc_sort = proptools.BoolPtr(true)
	}

	rule := android.NewRuleBuilder()

	if ctx.Config().FlattenApex() {
		for _, src := range m.fileContextsProperties.Flatten_apex.Srcs {
			if m := android.SrcIsModule(src); m != "" {
				ctx.ModuleErrorf(
					"Module srcs dependency %q is not supported for flatten_apex.srcs", m)
				return
			}
			for _, path := range android.PathsForModuleSrcExcludes(ctx, []string{src}, nil) {
				out := android.PathForModuleGen(ctx, "flattened_apex", path.Rel())
				apex_path := "/system/apex/" + strings.Replace(
					strings.TrimSuffix(path.Base(), "-file_contexts"),
					".", "\\\\.", -1)

				rule.Command().
					Text("awk '/object_r/{printf(\""+apex_path+"%s\\n\",$0)}'").
					Input(path).
					FlagWithOutput("> ", out)

				inputs = append(inputs, out)
			}
		}
	}

	rule.Build(pctx, ctx, m.Name(), "flattened_apex_file_contexts")
	m.buildGeneralContexts(ctx, inputs)
}

func fileFactory() android.Module {
	m := newModule()
	m.AddProperties(&m.fileContextsProperties)
	m.build = m.buildFileContexts
	return m
}

func (m *selinuxContextsModule) buildHwServiceContexts(ctx android.ModuleContext, inputs android.Paths) {
	if m.properties.Remove_comment == nil {
		m.properties.Remove_comment = proptools.BoolPtr(true)
	}

	m.buildGeneralContexts(ctx, inputs)
}

func hwServiceFactory() android.Module {
	m := newModule()
	m.build = m.buildHwServiceContexts
	return m
}

func propertyFactory() android.Module {
	m := newModule()
	m.build = m.buildGeneralContexts
	return m
}

func serviceFactory() android.Module {
	m := newModule()
	m.build = m.buildGeneralContexts
	return m
}
