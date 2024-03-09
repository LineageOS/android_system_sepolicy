The policy defines multiple types and attributes for apps. This document is a
high-level overview of these. For further details on each type, refer to their
specific files in the public/ and private/ directories.

## appdomain
In general, all apps will have the `appdomain` attribute. You can think of
`appdomain` as any app started by Zygote. The macro `app_domain()` should be
used to define a type that is considered an app (see public/te_macros).

## untrusted_app
Third-party apps (for example, installed from the Play Store), targeting the
most recent SDK version will be typed as `untrusted_app`. This is the default
domain for apps, unless a more specific criteria applies.

When an app is targeting a previous SDK version, it may have the
`untrusted_app_xx` type where xx is the targetSdkVersion. For instance, an app
with `targetSdkVersion = 32` in its manifest will be typed as `untrusted_app_32`.
Not all targetSdkVersion have a specific type, some version are skipped when no
differences were introduced (see public/untrusted_app.te for more details).

The `untrusted_app_all` attribute can be used to reference all the types
described in this section (that is, `untrusted_app`, `untrusted_app_30`,
`untrusted_app_32`, etc.).

## isolated_app
Apps may be restricted when using isolatedProcess=true in their manifest. In
this case, they will be assigned the `isolated_app` type. A similar type
`isolated_compute_app` exist for some restricted services.

Both types `isolated_app` and `isolated_compute_app` are grouped under the
attribute `isolated_app_all`.

## ephemeral_app
Apps that are run without installation. These are apps deployed for example via
Google Play Instant. These are more constrained than `untrusted_app`.

## sdk_sandbox
SDK runtime apps, installed as part of the Privacy Sandbox project. These are
sandboxed to limit their communication channels.

## platform_app
Apps that are signed with the platform key. These are installed within the
system or vendor image. com.android.systemui is an example of an app running
with this type.

## system_app
Apps pre-installed on a device, signed by the platform key and running with the
system UID. com.android.settings is an example of an app running with this
type.

## priv_app
Apps shipped as part of the device and installed in one of the
`/{system,vendor,product}/priv-app` directories.
com.google.android.apps.messaging is an example of an app running as priv_app.
Permissions for these apps need to be explicitly granted, see
https://source.android.com/docs/core/permissions/perms-allowlist for more
details.
