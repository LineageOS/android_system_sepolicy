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

type seappProperties struct {
	// Files containing neverallow rules.
	Neverallow_files []string `android:"path"`

	// Precompiled sepolicy binary file which will be fed to checkseapp.
	Sepolicy *string `android:"path"`
}

type selinuxContextsModule struct {
	android.ModuleBase
	android.DefaultableModuleBase
	flaggableModuleBase

	properties      selinuxContextsProperties
	seappProperties seappProperties
	build           func(ctx android.ModuleContext, inputs android.Paths) android.Path
	deps            func(ctx android.BottomUpMutatorContext)
	outputPath      android.Path
	installPath     android.InstallPath
}

var _ flaggableModule = (*selinuxContextsModule)(nil)

var (
	reuseContextsDepTag  = dependencyTag{name: "reuseContexts"}
	syspropLibraryDepTag = dependencyTag{name: "sysprop_library"}
)

func init() {
	pctx.HostBinToolVariable("fc_sort", "fc_sort")

	android.RegisterModuleType("contexts_defaults", contextsDefaultsFactory)
	android.RegisterModuleType("file_contexts", fileFactory)
	android.RegisterModuleType("hwservice_contexts", hwServiceFactory)
	android.RegisterModuleType("property_contexts", propertyFactory)
	android.RegisterModuleType("service_contexts", serviceFactory)
	android.RegisterModuleType("keystore2_key_contexts", keystoreKeyFactory)
	android.RegisterModuleType("seapp_contexts", seappFactory)
	android.RegisterModuleType("vndservice_contexts", vndServiceFactory)

	android.RegisterModuleType("file_contexts_test", fileContextsTestFactory)
	android.RegisterModuleType("property_contexts_test", propertyContextsTestFactory)
	android.RegisterModuleType("hwservice_contexts_test", hwserviceContextsTestFactory)
	android.RegisterModuleType("service_contexts_test", serviceContextsTestFactory)
	android.RegisterModuleType("vndservice_contexts_test", vndServiceContextsTestFactory)
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
	m.flagDeps(ctx)

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
		&m.seappProperties,
	)
	initFlaggableModule(m)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	android.InitDefaultableModule(m)
	android.AddLoadHook(m, func(ctx android.LoadHookContext) {
		m.selinuxContextsHook(ctx)
	})
	return m
}

type contextsDefaults struct {
	android.ModuleBase
	android.DefaultsModuleBase
}

// contexts_defaults provides a set of properties that can be inherited by other contexts modules.
// (file_contexts, property_contexts, seapp_contexts, etc.) A module can use the properties from a
// contexts_defaults using `defaults: ["<:default_module_name>"]`. Properties of both modules are
// erged (when possible) by prepending the default module's values to the depending module's values.
func contextsDefaultsFactory() android.Module {
	m := &contextsDefaults{}
	m.AddProperties(
		&selinuxContextsProperties{},
		&seappProperties{},
		&flaggableModuleProperties{},
	)
	android.InitDefaultsModule(m)
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
				fmt.Fprintln(w, "LOCAL_MODULE_PATH :=", m.installPath.String())
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
	builtContext := pathForModuleOut(ctx, ctx.ModuleName()+"_m4out")

	rule := android.NewRuleBuilder(pctx, ctx)

	newlineFile := pathForModuleOut(ctx, "newline")

	rule.Command().Text("echo").FlagWithOutput("> ", newlineFile)
	rule.Temporary(newlineFile)

	var inputsWithNewline android.Paths
	for _, input := range inputs {
		inputsWithNewline = append(inputsWithNewline, input, newlineFile)
	}

	flags := m.getBuildFlags(ctx)
	rule.Command().
		Tool(ctx.Config().PrebuiltBuildTool(ctx, "m4")).
		Text("--fatal-warnings -s").
		FlagForEachArg("-D", ctx.DeviceConfig().SepolicyM4Defs()).
		Flags(flagsToM4Macros(flags)).
		Inputs(inputsWithNewline).
		FlagWithOutput("> ", builtContext)

	if proptools.Bool(m.properties.Remove_comment) {
		rule.Temporary(builtContext)

		remove_comment_output := pathForModuleOut(ctx, ctx.ModuleName()+"_remove_comment")

		rule.Command().
			Text("sed -e 's/#.*$//' -e '/^$/d'").
			Input(builtContext).
			FlagWithOutput("> ", remove_comment_output)

		builtContext = remove_comment_output
	}

	if proptools.Bool(m.properties.Fc_sort) {
		rule.Temporary(builtContext)

		sorted_output := pathForModuleOut(ctx, ctx.ModuleName()+"_sorted")

		rule.Command().
			Tool(ctx.Config().HostToolPath(ctx, "fc_sort")).
			FlagWithInput("-i ", builtContext).
			FlagWithOutput("-o ", sorted_output)

		builtContext = sorted_output
	}

	ret := pathForModuleOut(ctx, m.stem())
	rule.Temporary(builtContext)
	rule.Command().Text("cp").Input(builtContext).Output(ret)

	rule.DeleteTemporaryFiles()
	rule.Build("selinux_contexts", "building contexts: "+m.Name())

	return ret
}

func (m *selinuxContextsModule) buildFileContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	if m.properties.Remove_comment == nil {
		m.properties.Remove_comment = proptools.BoolPtr(true)
	}
	return m.buildGeneralContexts(ctx, inputs)
}

func fileFactory() android.Module {
	m := newModule()
	m.build = m.buildFileContexts
	return m
}

func (m *selinuxContextsModule) buildServiceContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	if m.properties.Remove_comment == nil {
		m.properties.Remove_comment = proptools.BoolPtr(true)
	}

	return m.buildGeneralContexts(ctx, inputs)
}

func (m *selinuxContextsModule) checkVendorPropertyNamespace(ctx android.ModuleContext, input android.Path) android.Path {
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

	cmd := rule.Command().
		BuiltTool("check_prop_prefix").
		FlagWithInput("--property-contexts ", input).
		FlagForEachArg("--allowed-property-prefix ", proptools.ShellEscapeList(allowedPropertyPrefixes)). // contains shell special character '$'
		FlagForEachArg("--allowed-context-prefix ", allowedContextPrefixes)

	if !ctx.DeviceConfig().BuildBrokenVendorPropertyNamespace() {
		cmd.Flag("--strict")
	}

	out := pathForModuleOut(ctx, ctx.ModuleName()+"_namespace_checked")
	rule.Command().Text("cp -f").Input(input).Output(out)
	rule.Build("check_namespace", "checking namespace of "+ctx.ModuleName())
	return out
}

func (m *selinuxContextsModule) buildPropertyContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	// vendor/odm properties are enforced for devices launching with Android Q or later. So, if
	// vendor/odm, make sure that only vendor/odm properties exist.
	builtCtxFile := m.buildGeneralContexts(ctx, inputs)

	shippingApiLevel := ctx.DeviceConfig().ShippingApiLevel()
	ApiLevelQ := android.ApiLevelOrPanic(ctx, "Q")
	if (ctx.SocSpecific() || ctx.DeviceSpecific()) && shippingApiLevel.GreaterThanOrEqualTo(ApiLevelQ) {
		builtCtxFile = m.checkVendorPropertyNamespace(ctx, builtCtxFile)
	}

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
		out := pathForModuleOut(ctx, ctx.ModuleName()+"_api_checked")
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

func (m *selinuxContextsModule) shouldCheckCoredomain(ctx android.ModuleContext) bool {
	if !ctx.SocSpecific() && !ctx.DeviceSpecific() {
		return false
	}

	return ctx.DeviceConfig().CheckVendorSeappViolations()
}

func (m *selinuxContextsModule) buildSeappContexts(ctx android.ModuleContext, inputs android.Paths) android.Path {
	neverallowFile := pathForModuleOut(ctx, "neverallow")
	ret := pathForModuleOut(ctx, "checkseapp", m.stem())

	// Step 1. Generate a M4 processed neverallow file
	flags := m.getBuildFlags(ctx)
	m4NeverallowFile := pathForModuleOut(ctx, "neverallow.m4out")
	rule := android.NewRuleBuilder(pctx, ctx)
	rule.Command().
		Tool(ctx.Config().PrebuiltBuildTool(ctx, "m4")).
		Flag("--fatal-warnings").
		FlagForEachArg("-D", ctx.DeviceConfig().SepolicyM4Defs()).
		Flags(flagsToM4Macros(flags)).
		Inputs(android.PathsForModuleSrc(ctx, m.seappProperties.Neverallow_files)).
		FlagWithOutput("> ", m4NeverallowFile)

	rule.Temporary(m4NeverallowFile)
	rule.Command().
		Text("( grep").
		Flag("-ihe").
		Text("'^neverallow'").
		Input(m4NeverallowFile).
		Text(">").
		Output(neverallowFile).
		Text("|| true )") // to make ninja happy even when result is empty

	// Step 2. Generate a M4 processed contexts file
	builtCtx := m.buildGeneralContexts(ctx, inputs)

	// Step 3. checkseapp
	rule.Temporary(neverallowFile)
	checkCmd := rule.Command().BuiltTool("checkseapp").
		FlagWithInput("-p ", android.PathForModuleSrc(ctx, proptools.String(m.seappProperties.Sepolicy))).
		FlagWithOutput("-o ", ret).
		Input(builtCtx).
		Input(neverallowFile)

	if m.shouldCheckCoredomain(ctx) {
		checkCmd.Flag("-c") // check coredomain for vendor contexts
	}

	rule.Build("seapp_contexts", "Building seapp_contexts: "+m.Name())
	return ret
}

func hwServiceFactory() android.Module {
	m := newModule()
	m.build = m.buildServiceContexts
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
	m.build = m.buildServiceContexts
	return m
}

func keystoreKeyFactory() android.Module {
	m := newModule()
	m.build = m.buildGeneralContexts
	return m
}

func seappFactory() android.Module {
	m := newModule()
	m.build = m.buildSeappContexts
	return m
}

func vndServiceFactory() android.Module {
	m := newModule()
	m.build = m.buildGeneralContexts
	android.AddLoadHook(m, func(ctx android.LoadHookContext) {
		if !ctx.SocSpecific() {
			ctx.ModuleErrorf(m.Name(), "must set vendor: true")
			return
		}
	})
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

type contextsTestProperties struct {
	// Contexts files to be tested.
	Srcs []string `android:"path"`

	// Precompiled sepolicy binary to be tesed together.
	Sepolicy *string `android:"path"`
}

type fileContextsTestProperties struct {
	// Test data. File passed to `checkfc -t` to validate how contexts are resolved.
	Test_data *string `android:"path"`
}

type contextsTestModule struct {
	android.ModuleBase

	// The type of context.
	context contextType

	properties     contextsTestProperties
	fileProperties fileContextsTestProperties
	testTimestamp  android.OutputPath
}

type contextType int

const (
	FileContext contextType = iota
	PropertyContext
	ServiceContext
	HwServiceContext
	VndServiceContext
)

// checkfc parses a context file and checks for syntax errors.
// If -s is specified, the service backend is used to verify binder services.
// If -l is specified, the service backend is used to verify hwbinder services.
// Otherwise, context_file is assumed to be a file_contexts file
// If -e is specified, then the context_file is allowed to be empty.

// file_contexts_test tests given file_contexts files with checkfc.
func fileContextsTestFactory() android.Module {
	m := &contextsTestModule{context: FileContext}
	m.AddProperties(&m.properties)
	m.AddProperties(&m.fileProperties)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	return m
}

// property_contexts_test tests given property_contexts files with property_info_checker.
func propertyContextsTestFactory() android.Module {
	m := &contextsTestModule{context: PropertyContext}
	m.AddProperties(&m.properties)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	return m
}

// hwservice_contexts_test tests given hwservice_contexts files with checkfc.
func hwserviceContextsTestFactory() android.Module {
	m := &contextsTestModule{context: HwServiceContext}
	m.AddProperties(&m.properties)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	return m
}

// service_contexts_test tests given service_contexts files with checkfc.
func serviceContextsTestFactory() android.Module {
	// checkfc -s: service_contexts test
	m := &contextsTestModule{context: ServiceContext}
	m.AddProperties(&m.properties)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	return m
}

// vndservice_contexts_test tests given vndservice_contexts files with checkfc.
func vndServiceContextsTestFactory() android.Module {
	m := &contextsTestModule{context: VndServiceContext}
	m.AddProperties(&m.properties)
	android.InitAndroidArchModule(m, android.DeviceSupported, android.MultilibCommon)
	return m
}

func (m *contextsTestModule) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	tool := "checkfc"
	if m.context == PropertyContext {
		tool = "property_info_checker"
	}

	if len(m.properties.Srcs) == 0 {
		ctx.PropertyErrorf("srcs", "can't be empty")
		return
	}

	validateWithPolicy := true
	if proptools.String(m.properties.Sepolicy) == "" {
		if m.context == FileContext {
			if proptools.String(m.fileProperties.Test_data) == "" {
				ctx.PropertyErrorf("test_data", "Either test_data or sepolicy should be provided")
				return
			}
			validateWithPolicy = false
		} else {
			ctx.PropertyErrorf("sepolicy", "can't be empty")
			return
		}
	}

	flags := []string(nil)
	switch m.context {
	case FileContext:
		if !validateWithPolicy {
			flags = []string{"-t"}
		}
	case ServiceContext:
		flags = []string{"-s" /* binder services */}
	case HwServiceContext:
		flags = []string{"-e" /* allow empty */, "-l" /* hwbinder services */}
	case VndServiceContext:
		flags = []string{"-e" /* allow empty */, "-v" /* vnd service */}
	}

	srcs := android.PathsForModuleSrc(ctx, m.properties.Srcs)
	rule := android.NewRuleBuilder(pctx, ctx)

	if validateWithPolicy {
		sepolicy := android.PathForModuleSrc(ctx, proptools.String(m.properties.Sepolicy))
		rule.Command().BuiltTool(tool).
			Flags(flags).
			Input(sepolicy).
			Inputs(srcs)
	} else {
		test_data := android.PathForModuleSrc(ctx, proptools.String(m.fileProperties.Test_data))
		rule.Command().BuiltTool(tool).
			Flags(flags).
			Inputs(srcs).
			Input(test_data)
	}

	m.testTimestamp = pathForModuleOut(ctx, "timestamp")
	rule.Command().Text("touch").Output(m.testTimestamp)
	rule.Build("contexts_test", "running contexts test: "+ctx.ModuleName())
}

func (m *contextsTestModule) AndroidMkEntries() []android.AndroidMkEntries {
	return []android.AndroidMkEntries{android.AndroidMkEntries{
		Class: "FAKE",
		// OutputFile is needed, even though BUILD_PHONY_PACKAGE doesn't use it.
		// Without OutputFile this module won't be exported to Makefile.
		OutputFile: android.OptionalPathForPath(m.testTimestamp),
		Include:    "$(BUILD_PHONY_PACKAGE)",
		ExtraEntries: []android.AndroidMkExtraEntriesFunc{
			func(ctx android.AndroidMkExtraEntriesContext, entries *android.AndroidMkEntries) {
				entries.SetString("LOCAL_ADDITIONAL_DEPENDENCIES", m.testTimestamp.String())
			},
		},
	}}
}

// contextsTestModule implements ImageInterface to be able to include recovery_available contexts
// modules as its sources.
func (m *contextsTestModule) ImageMutatorBegin(ctx android.BaseModuleContext) {
}

func (m *contextsTestModule) CoreVariantNeeded(ctx android.BaseModuleContext) bool {
	return true
}

func (m *contextsTestModule) RamdiskVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *contextsTestModule) VendorRamdiskVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *contextsTestModule) DebugRamdiskVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *contextsTestModule) RecoveryVariantNeeded(ctx android.BaseModuleContext) bool {
	return false
}

func (m *contextsTestModule) ExtraImageVariations(ctx android.BaseModuleContext) []string {
	return nil
}

func (m *contextsTestModule) SetImageVariation(ctx android.BaseModuleContext, variation string, module android.Module) {
}

var _ android.ImageInterface = (*contextsTestModule)(nil)
