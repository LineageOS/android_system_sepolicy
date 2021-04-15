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

	"github.com/google/blueprint"
	"github.com/google/blueprint/proptools"

	"android/soong/android"
	"android/soong/sysprop"
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
	build                  func(ctx android.ModuleContext, inputs android.Paths) android.Path
	deps                   func(ctx android.BottomUpMutatorContext)
	outputPath             android.Path
	installPath            android.InstallPath
}

var (
	reuseContextsDepTag  = dependencyTag{name: "reuseContexts"}
	syspropLibraryDepTag = dependencyTag{name: "sysprop_library"}
)

func init() {
	pctx.HostBinToolVariable("fc_sort", "fc_sort")

	android.RegisterModuleType("file_contexts", fileFactory)
	android.RegisterModuleType("hwservice_contexts", hwServiceFactory)
	android.RegisterModuleType("property_contexts", propertyFactory)
	android.RegisterModuleType("service_contexts", serviceFactory)
	android.RegisterModuleType("keystore2_key_contexts", keystoreKeyFactory)
}

func (m *selinuxContextsModule) InstallInRoot() bool {
	return m.InRecovery()
}

func (m *selinuxContextsModule) InstallInRecovery() bool {
	// ModuleBase.InRecovery() checks the image variant
	return m.InRecovery()
}

func (m *selinuxContextsModule) onlyInRecovery() bool {
	// ModuleBase.InstallInRecovery() checks commonProperties.Recovery property
	return m.ModuleBase.InstallInRecovery()
}

func (m *selinuxContextsModule) DepsMutator(ctx android.BottomUpMutatorContext) {
	if m.deps != nil {
		m.deps(ctx)
	}

	if m.InRecovery() && !m.onlyInRecovery() {
		ctx.AddFarVariationDependencies([]blueprint.Variation{
			{Mutator: "image", Variation: android.CoreVariation},
		}, reuseContextsDepTag, ctx.ModuleName())
	}
}

func (m *selinuxContextsModule) propertyContextsDeps(ctx android.BottomUpMutatorContext) {
	for _, lib := range sysprop.SyspropLibraries(ctx.Config()) {
		ctx.AddFarVariationDependencies([]blueprint.Variation{}, syspropLibraryDepTag, lib)
	}
}

func (m *selinuxContextsModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	if m.InRecovery() {
		// Installing context files at the root of the recovery partition
		m.installPath = android.PathForModuleInstall(ctx)
	} else {
		m.installPath = android.PathForModuleInstall(ctx, "etc", "selinux")
	}

	if m.InRecovery() && !m.onlyInRecovery() {
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
			if ctx.DeviceConfig().BoardSepolicyVers() == ctx.DeviceConfig().PlatformSepolicyVersion() {
				inputs = append(inputs, segroup.SystemVendorSrcs()...)
			}
			inputs = append(inputs, segroup.VendorSrcs()...)
		} else if ctx.DeviceSpecific() {
			inputs = append(inputs, segroup.OdmSrcs()...)
		} else if ctx.SystemExtSpecific() {
			inputs = append(inputs, segroup.SystemExtPrivateSrcs()...)
		} else {
			inputs = append(inputs, segroup.SystemPrivateSrcs()...)
			inputs = append(inputs, segroup.SystemPublicSrcs()...)
		}

		if proptools.Bool(m.properties.Reqd_mask) {
			if ctx.SocSpecific() || ctx.DeviceSpecific() {
				inputs = append(inputs, segroup.VendorReqdMaskSrcs()...)
			} else {
				inputs = append(inputs, segroup.SystemReqdMaskSrcs()...)
			}
		}
	})

	for _, src := range m.properties.Srcs {
		// Module sources are handled above with VisitDirectDepsWithTag
		if android.SrcIsModule(src) == "" {
			inputs = append(inputs, android.PathForModuleSrc(ctx, src))
		}
	}

	m.outputPath = m.build(ctx, inputs)
	ctx.InstallFile(m.installPath, ctx.ModuleName(), m.outputPath)
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
			if m.InRecovery() && !m.onlyInRecovery() {
				nameSuffix = ".recovery"
			}
			fmt.Fprintln(w, "\ninclude $(CLEAR_VARS)")
			fmt.Fprintln(w, "LOCAL_PATH :=", moduleDir)
			fmt.Fprintln(w, "LOCAL_MODULE :=", name+nameSuffix)
			data.Entries.WriteLicenseVariables(w)
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

func (m *selinuxContextsModule) ImageMutatorBegin(ctx android.BaseModuleContext) {
	if proptools.Bool(m.properties.Recovery_available) && m.InstallInRecovery() {
		ctx.PropertyErrorf("recovery_available",
			"doesn't make sense at the same time as `recovery: true`")
	}
}

func (m *selinuxContextsModule) CoreVariantNeeded(ctx android.BaseModuleContext) bool {
	return !m.InstallInRecovery()
}

func (m *selinuxContextsModule) RamdiskVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *selinuxContextsModule) VendorRamdiskVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *selinuxContextsModule) DebugRamdiskVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *selinuxContextsModule) RecoveryVariantNeeded(ctx android.BaseModuleContext) bool {
	return m.InstallInRecovery() || proptools.Bool(m.properties.Recovery_available)
}

func (m *selinuxContextsModule) ExtraImageVariations(ctx android.BaseModuleContext) []string {
	return nil
}

func (m *selinuxContextsModule) SetImageVariation(ctx android.BaseModuleContext, variation string, module android.Module) {
}

var _ android.ImageInterface = (*selinuxContextsModule)(nil)

func (m *selinuxContextsModule) buildGeneralContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	ret := android.PathForModuleGen(ctx, ctx.ModuleName()+"_m4out")

	rule := android.NewRuleBuilder(pctx, ctx)

	rule.Command().
		Tool(ctx.Config().PrebuiltBuildTool(ctx, "m4")).
		Text("--fatal-warnings -s").
		FlagForEachArg("-D", ctx.DeviceConfig().SepolicyM4Defs()).
		Inputs(inputs).
		FlagWithOutput("> ", ret)

	if proptools.Bool(m.properties.Remove_comment) {
		rule.Temporary(ret)

		remove_comment_output := android.PathForModuleGen(ctx, ctx.ModuleName()+"_remove_comment")

		rule.Command().
			Text("sed -e 's/#.*$//' -e '/^$/d'").
			Input(ret).
			FlagWithOutput("> ", remove_comment_output)

		ret = remove_comment_output
	}

	if proptools.Bool(m.properties.Fc_sort) {
		rule.Temporary(ret)

		sorted_output := android.PathForModuleGen(ctx, ctx.ModuleName()+"_sorted")

		rule.Command().
			Tool(ctx.Config().HostToolPath(ctx, "fc_sort")).
			FlagWithInput("-i ", ret).
			FlagWithOutput("-o ", sorted_output)

		ret = sorted_output
	}

	rule.Build("selinux_contexts", "building contexts: "+m.Name())

	rule.DeleteTemporaryFiles()

	return ret
}

func (m *selinuxContextsModule) buildFileContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	if m.properties.Fc_sort == nil {
		m.properties.Fc_sort = proptools.BoolPtr(true)
	}

	rule := android.NewRuleBuilder(pctx, ctx)

	if ctx.Config().FlattenApex() {
		for _, src := range m.fileContextsProperties.Flatten_apex.Srcs {
			if m := android.SrcIsModule(src); m != "" {
				ctx.ModuleErrorf(
					"Module srcs dependency %q is not supported for flatten_apex.srcs", m)
				return nil
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

	rule.Build(m.Name(), "flattened_apex_file_contexts")
	return m.buildGeneralContexts(ctx, inputs)
}

func fileFactory() android.Module {
	m := newModule()
	m.AddProperties(&m.fileContextsProperties)
	m.build = m.buildFileContexts
	return m
}

func (m *selinuxContextsModule) buildHwServiceContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	if m.properties.Remove_comment == nil {
		m.properties.Remove_comment = proptools.BoolPtr(true)
	}

	return m.buildGeneralContexts(ctx, inputs)
}

func (m *selinuxContextsModule) checkVendorPropertyNamespace(ctx android.ModuleContext, inputs android.Paths) android.Paths {
	shippingApiLevel := ctx.DeviceConfig().ShippingApiLevel()
	ApiLevelR := android.ApiLevelOrPanic(ctx, "R")

	rule := android.NewRuleBuilder(pctx, ctx)

	// This list is from vts_treble_sys_prop_test.
	allowedPropertyPrefixes := []string{
		"ctl.odm.",
		"ctl.vendor.",
		"ctl.start$odm.",
		"ctl.start$vendor.",
		"ctl.stop$odm.",
		"ctl.stop$vendor.",
		"init.svc.odm.",
		"init.svc.vendor.",
		"ro.boot.",
		"ro.hardware.",
		"ro.odm.",
		"ro.vendor.",
		"odm.",
		"persist.odm.",
		"persist.vendor.",
		"vendor.",
	}

	// persist.camera is also allowed for devices launching with R or eariler
	if shippingApiLevel.LessThanOrEqualTo(ApiLevelR) {
		allowedPropertyPrefixes = append(allowedPropertyPrefixes, "persist.camera.")
	}

	var allowedContextPrefixes []string

	if shippingApiLevel.GreaterThanOrEqualTo(ApiLevelR) {
		// This list is from vts_treble_sys_prop_test.
		allowedContextPrefixes = []string{
			"vendor_",
			"odm_",
		}
	}

	var ret android.Paths
	for _, input := range inputs {
		cmd := rule.Command().
			BuiltTool("check_prop_prefix").
			FlagWithInput("--property-contexts ", input).
			FlagForEachArg("--allowed-property-prefix ", proptools.ShellEscapeList(allowedPropertyPrefixes)). // contains shell special character '$'
			FlagForEachArg("--allowed-context-prefix ", allowedContextPrefixes)

		if !ctx.DeviceConfig().BuildBrokenVendorPropertyNamespace() {
			cmd.Flag("--strict")
		}

		out := android.PathForModuleGen(ctx, "namespace_checked").Join(ctx, input.String())
		rule.Command().Text("cp -f").Input(input).Output(out)
		ret = append(ret, out)
	}
	rule.Build("check_namespace", "checking namespace of "+ctx.ModuleName())
	return ret
}

func (m *selinuxContextsModule) buildPropertyContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	// vendor/odm properties are enforced for devices launching with Android Q or later. So, if
	// vendor/odm, make sure that only vendor/odm properties exist.
	shippingApiLevel := ctx.DeviceConfig().ShippingApiLevel()
	ApiLevelQ := android.ApiLevelOrPanic(ctx, "Q")
	if (ctx.SocSpecific() || ctx.DeviceSpecific()) && shippingApiLevel.GreaterThanOrEqualTo(ApiLevelQ) {
		inputs = m.checkVendorPropertyNamespace(ctx, inputs)
	}

	builtCtxFile := m.buildGeneralContexts(ctx, inputs)

	var apiFiles android.Paths
	ctx.VisitDirectDepsWithTag(syspropLibraryDepTag, func(c android.Module) {
		i, ok := c.(interface{ CurrentSyspropApiFile() android.OptionalPath })
		if !ok {
			panic(fmt.Errorf("unknown dependency %q for %q", ctx.OtherModuleName(c), ctx.ModuleName()))
		}
		if api := i.CurrentSyspropApiFile(); api.Valid() {
			apiFiles = append(apiFiles, api.Path())
		}
	})

	// check compatibility with sysprop_library
	if len(apiFiles) > 0 {
		out := android.PathForModuleGen(ctx, ctx.ModuleName()+"_api_checked")
		rule := android.NewRuleBuilder(pctx, ctx)

		msg := `\n******************************\n` +
			`API of sysprop_library doesn't match with property_contexts\n` +
			`Please fix the breakage and rebuild.\n` +
			`******************************\n`

		rule.Command().
			Text("( ").
			BuiltTool("sysprop_type_checker").
			FlagForEachInput("--api ", apiFiles).
			FlagWithInput("--context ", builtCtxFile).
			Text(" || ( echo").Flag("-e").
			Flag(`"` + msg + `"`).
			Text("; exit 38) )")

		rule.Command().Text("cp -f").Input(builtCtxFile).Output(out)
		rule.Build("property_contexts_check_api", "checking API: "+m.Name())
		builtCtxFile = out
	}

	return builtCtxFile
}

func hwServiceFactory() android.Module {
	m := newModule()
	m.build = m.buildHwServiceContexts
	return m
}

func propertyFactory() android.Module {
	m := newModule()
	m.build = m.buildPropertyContexts
	m.deps = m.propertyContextsDeps
	return m
}

func serviceFactory() android.Module {
	m := newModule()
	m.build = m.buildGeneralContexts
	return m
}

func keystoreKeyFactory() android.Module {
	m := newModule()
	m.build = m.buildGeneralContexts
	return m
}
