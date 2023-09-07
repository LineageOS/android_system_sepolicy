#!/bin/bash

MK=$(awk -F= '/PolicyVers/ { print $2 }' build/soong/policy.go | tr -d ' [:space:]')
BP=$(awk -F= '/DSEPOLICY_VERSION/ { print $2 }' Android.bp | awk -F\" ' { print $1 }')

if [ "$MK" != "$BP" ]; then
    echo "POLICYVERS in Android.mk must match DSEPOLICY_VERSION in Android.bp" 1>&2
    exit 1
fi
