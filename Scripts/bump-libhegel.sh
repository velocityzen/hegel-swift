#!/usr/bin/env bash
# Moves the package to another libhegel release.
#
#   Scripts/bump-libhegel.sh <version>
#       Packages that release (Scripts/package-libhegel.sh), then applies it.
#
#   Scripts/bump-libhegel.sh --apply <checksums.env>
#       Applies an already packaged release: writes its version and the
#       checksums of its zips into LIBHEGEL_VERSION, Package.swift and
#       Sources/Hegel/Engine/EngineVersion.swift. A checksum missing from the
#       file (an artifact the packaging host could not build) is left as is.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--apply" ]; then
    env_file="$2"
else
    version="${1:?usage: bump-libhegel.sh <version> | --apply <checksums.env>}"
    "$root/Scripts/package-libhegel.sh" "$version"
    env_file="$root/Artifacts/checksums.env"
fi

# shellcheck disable=SC1090
source "$env_file"

replace() {
    local file="$1" pattern="$2" replacement="$3"
    local tmp
    tmp="$(mktemp)"
    sed -E "s|$pattern|$replacement|" "$file" > "$tmp"
    mv "$tmp" "$file"
}

echo "$LIBHEGEL_VERSION" > "$root/LIBHEGEL_VERSION"
replace "$root/Package.swift" \
    '^let libhegelVersion = ".*"' "let libhegelVersion = \"$LIBHEGEL_VERSION\""
replace "$root/Sources/Hegel/Engine/EngineVersion.swift" \
    '^public let expectedEngineVersion = ".*"' "public let expectedEngineVersion = \"$LIBHEGEL_VERSION\""
if [ -n "${XCFRAMEWORK_CHECKSUM:-}" ]; then
    replace "$root/Package.swift" \
        '^let xcframeworkChecksum = ".*"' "let xcframeworkChecksum = \"$XCFRAMEWORK_CHECKSUM\""
fi
if [ -n "${ARTIFACTBUNDLE_CHECKSUM:-}" ]; then
    replace "$root/Package.swift" \
        '^let artifactbundleChecksum = ".*"' "let artifactbundleChecksum = \"$ARTIFACTBUNDLE_CHECKSUM\""
fi

echo "Package now targets libhegel $LIBHEGEL_VERSION"
