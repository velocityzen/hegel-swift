#!/usr/bin/env bash
# Downloads a libhegel release from hegeldev/hegel and repackages it for
# SwiftPM:
#
#   Artifacts/CHegel.xcframework            macOS (Apple platforms)
#   Artifacts/CHegel.artifactbundle         Linux (static library bundle)
#   Artifacts/CHegel.xcframework.zip        what a release uploads
#   Artifacts/CHegel.artifactbundle.zip
#   Artifacts/checksums.env                 SwiftPM checksums of the zips
#
# Every downloaded file is checked against the .sha256 file upstream
# publishes next to it. hegel.h is copied unchanged into
# libhegel, so a version bump shows its ABI diff in review.
#
# Usage: Scripts/package-libhegel.sh [version]
#        (defaults to the version in LIBHEGEL_VERSION)

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-$(tr -d '[:space:]' < "$root/LIBHEGEL_VERSION")}"
tag="libhegel/$version"
base="https://github.com/hegeldev/hegel/releases/download/$tag"

work="$root/.build/libhegel-$version"
out="$root/Artifacts"
rm -rf "$work" "$out"
mkdir -p "$work/download" "$out"

files=(
    hegel.h
    libhegel-darwin-arm64.a
    libhegel-linux-amd64.a
    libhegel-linux-arm64.a
)

echo "Downloading $tag"
for file in "${files[@]}"; do
    curl -fsSL --retry 3 -o "$work/download/$file" "$base/$file"
    curl -fsSL --retry 3 -o "$work/download/$file.sha256" "$base/$file.sha256"
done

sha256() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

echo "Verifying checksums"
(
    cd "$work/download"
    for file in "${files[@]}"; do
        expected="$(awk '{print $1}' "$file.sha256")"
        actual="$(sha256 "$file")"
        if [ "$expected" != "$actual" ]; then
            echo "error: checksum mismatch for $file" >&2
            exit 1
        fi
    done
)

cp "$work/download/hegel.h" "$root/libhegel/hegel.h"

# Headers shared by every slice: the upstream header and a module map that
# names the Swift module `CHegel`.
make_headers() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    cp "$work/download/hegel.h" "$dir/hegel.h"
    {
        echo "module CHegel {"
        echo "    header \"hegel.h\""
        for lib in "$@"; do
            echo "    link \"$lib\""
        done
        echo "    export *"
        echo "}"
    } > "$dir/module.modulemap"
}

if [ "$(uname -s)" = "Darwin" ]; then
    echo "Building CHegel.xcframework"
    make_headers "$work/macos/include"
    cp "$work/download/libhegel-darwin-arm64.a" "$work/macos/libhegel.a"
    xcodebuild -create-xcframework \
        -library "$work/macos/libhegel.a" \
        -headers "$work/macos/include" \
        -output "$out/CHegel.xcframework" > /dev/null
    (cd "$out" && zip -qry -X CHegel.xcframework.zip CHegel.xcframework)
fi

echo "Building CHegel.artifactbundle"
bundle="$out/CHegel.artifactbundle"
for arch in amd64 arm64; do
    slice="$bundle/linux-$arch"
    make_headers "$slice/include" pthread dl m
    cp "$work/download/libhegel-linux-$arch.a" "$slice/libhegel.a"
done
cat > "$bundle/info.json" << JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "CHegel": {
      "type": "staticLibrary",
      "version": "$version",
      "variants": [
        {
          "path": "linux-amd64/libhegel.a",
          "supportedTriples": ["x86_64-unknown-linux-gnu"],
          "staticLibraryMetadata": {
            "headerPaths": ["linux-amd64/include"],
            "moduleMapPath": "linux-amd64/include/module.modulemap"
          }
        },
        {
          "path": "linux-arm64/libhegel.a",
          "supportedTriples": ["aarch64-unknown-linux-gnu"],
          "staticLibraryMetadata": {
            "headerPaths": ["linux-arm64/include"],
            "moduleMapPath": "linux-arm64/include/module.modulemap"
          }
        }
      ]
    }
  }
}
JSON
(cd "$out" && zip -qry -X CHegel.artifactbundle.zip CHegel.artifactbundle)

checksum() {
    if command -v swift > /dev/null; then
        swift package --package-path "$root" compute-checksum "$1"
    else
        sha256 "$1"
    fi
}

{
    echo "LIBHEGEL_VERSION=$version"
    if [ -f "$out/CHegel.xcframework.zip" ]; then
        echo "XCFRAMEWORK_CHECKSUM=$(checksum "$out/CHegel.xcframework.zip")"
    fi
    echo "ARTIFACTBUNDLE_CHECKSUM=$(checksum "$out/CHegel.artifactbundle.zip")"
} > "$out/checksums.env"

echo "Done:"
cat "$out/checksums.env"
