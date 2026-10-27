#!/bin/bash
# Keep XCTest's host app out of the development app the user opens.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_data="$project_root/../work/TestDerivedData"
source_packages="$project_root/../work/SourcePackages"

# A test must never overwrite a different app or read the user's actual store.
for argument in "$@"; do
    case "$argument" in
        -only-testing:*|-skip-testing:*) ;;
        *)
            echo "Only -only-testing:... and -skip-testing:... selectors are accepted; build output and identity are fixed." >&2
            exit 2
            ;;
    esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Xcode gives this environment-supplied xcconfig precedence over CLI settings.
unset XCODE_XCCONFIG_FILE
cd "$project_root"
exec xcodebuild test \
    -project TheAll.xcodeproj -scheme TheAllTests -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$test_data" -clonedSourcePackagesDirPath "$source_packages" \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    THEALL_APP_IDENTIFIER=com.theall.tests.local THEALL_PREVIOUS_NAMESPACE= \
    "$@"
