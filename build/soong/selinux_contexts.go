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

	// Output file name. Defaults to module name
	Stem *string

	Product_variables struct {
		Address_sanitize struct {
			Srcs []string `android:"path"`
		}
	}

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
		Srcs []string `android:"path"`
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

func (m *selinuxContextsModule) stem() string {
	return proptools.StringDefault(m.properties.Stem, m.Name())
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
			ctx.InstallFile(m.installPath, m.stem(), m.outputPath)
			return
		}
	}

	m.outputPath = m.build(ctx, android.PathsForModuleSrc(ctx, m.properties.Srcs))
	ctx.InstallFile(m.installPath, m.stem(), m.outputPath)
}

func newModule() *selinuxContextsModule {
	m := &selinuxContextsModule{}
	m.AddProperties(
		&m.properties,
		&m.fileContextsProperties,
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

	for _, sanitize := range ctx.Config().SanitizeDevice() {
		if sanitize == "address" {
			srcs = append(srcs, m.properties.Product_variables.Address_sanitize.Srcs...)
			break
		}
	}

	m.properties.Srcs = append(m.properties.Srcs, srcs...)
}

func (m *selinuxContextsModule) AndroidMk() android.AndroidMkData {
	nameSuffix := ""
	if m.InRecovery() && !m.onlyInRecovery() {
		nameSuffix = ".recovery"
	}
	return android.AndroidMkData{
		Class:      "ETC",
		OutputFile: android.OptionalPathForPath(m.outputPath),
		SubName:    nameSuffix,
		Extra: []android.AndroidMkExtraFunc{
			func(w io.Writer, outputFile android.Path) {
				fmt.Fprintln(w, "LOCAL_MODULE_PATH :=", m.installPath.ToMakePath().String())
				fmt.Fprintln(w, "LOCAL_INSTALLED_MODULE_STEM :=", m.stem())
			},
		},
	}
}

func (m *selinuxContextsModule) ImageMutatorBegin(ctx android.BaseModuleContext) {
	if proptools.Bool(m.properties.Recovery_available) && m.ModuleBase.InstallInRecovery() {
		ctx.PropertyErrorf("recovery_available",
			"doesn't make sense at the same time as `recovery: true`")
	}
}

func (m *selinuxContextsModule) CoreVariantNeeded(ctx android.BaseModuleContext) bool {
	return !m.ModuleBase.InstallInRecovery()
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
	return m.ModuleBase.InstallInRecovery() || proptools.Bool(m.properties.Recovery_available)
}

func (m *selinuxContextsModule) ExtraImageVariations(ctx android.BaseModuleContext) []string {
	return nil
}

func (m *selinuxContextsModule) SetImageVariation(ctx android.BaseModuleContext, variation string, module android.Module) {
}

var _ android.ImageInterface = (*selinuxContextsModule)(nil)

func (m *selinuxContextsModule) buildGeneralContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	builtContext := android.PathForModuleGen(ctx, ctx.ModuleName()+"_m4out")

	rule := android.NewRuleBuilder(pctx, ctx)

	rule.Command().
		Tool(ctx.Config().PrebuiltBuildTool(ctx, "m4")).
		Text("--fatal-warnings -s").
		FlagForEachArg("-D", ctx.DeviceConfig().SepolicyM4Defs()).
		Inputs(inputs).
		FlagWithOutput("> ", builtContext)

	if proptools.Bool(m.properties.Remove_comment) {
		rule.Temporary(builtContext)

		remove_comment_output := android.PathForModuleGen(ctx, ctx.ModuleName()+"_remove_comment")

		rule.Command().
			Text("sed -e 's/#.*$//' -e '/^$/d'").
			Input(builtContext).
			FlagWithOutput("> ", remove_comment_output)

		builtContext = remove_comment_output
	}

	if proptools.Bool(m.properties.Fc_sort) {
		rule.Temporary(builtContext)

		sorted_output := android.PathForModuleGen(ctx, ctx.ModuleName()+"_sorted")

		rule.Command().
			Tool(ctx.Config().HostToolPath(ctx, "fc_sort")).
			FlagWithInput("-i ", builtContext).
			FlagWithOutput("-o ", sorted_output)

		builtContext = sorted_output
	}

	ret := android.PathForModuleGen(ctx, m.stem())
	rule.Temporary(builtContext)
	rule.Command().Text("cp").Input(builtContext).Output(ret)

	rule.DeleteTemporaryFiles()
	rule.Build("selinux_contexts", "building contexts: "+m.Name())

	return ret
}

func (m *selinuxContextsModule) buildFileContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	if m.properties.Fc_sort == nil {
		m.properties.Fc_sort = proptools.BoolPtr(true)
	}

	rule := android.NewRuleBuilder(pctx, ctx)

	if ctx.Config().FlattenApex() {
		for _, path := range android.PathsForModuleSrc(ctx, m.fileContextsProperties.Flatten_apex.Srcs) {
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

	rule.Build(m.Name(), "flattened_apex_file_contexts")
	return m.buildGeneralContexts(ctx, inputs)
}

func fileFactory() android.Module {
	m := newModule()
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

var _ android.OutputFileProducer = (*selinuxContextsModule)(nil)

// Implements android.OutputFileProducer
func (m *selinuxContextsModule) OutputFiles(tag string) (android.Paths, error) {
	if tag == "" {
		return []android.Path{m.outputPath}, nil
	}
	return nil, fmt.Errorf("unsupported module reference tag %q", tag)
}
