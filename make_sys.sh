#!/usr/bin/env bash

# NOTE: this script is only intended to be run on CI.
set -xe

export PATH="$HOME/.cargo/bin/":"$PATH"

DESTINATION=tracy-git

rm -rf "${DESTINATION}"
git clone https://github.com/IntroversionSoftware/gamelibs-tracy.git "${DESTINATION}"

TAG="$(cd tracy-git && git describe --tags --abbrev=0)"

echo "tracy-tag=$TAG" >> "${GITHUB_OUTPUT:-/dev/stdout}"
BASEDIR="$(readlink -f $DESTINATION)"

rm -rf "tracy-client-sys/tracy/"
cp -r "$BASEDIR/public" "tracy-client-sys/tracy"
cp "$BASEDIR/LICENSE" "tracy-client-sys/tracy/"

COMMON_BINDGEN_PARAMS=(
    "tracy-client-sys/tracy/tracy/TracyC.h"
    "--disable-header-comment"
    "--"
    "-DTRACY_ENABLE"
)

bindgen -o "tracy-client-sys/src/generated.rs" \
  --rust-target 1.70.0 \
  --allowlist-function='.*[Tt][Rr][Aa][Cc][Yy].*' \
  --allowlist-type='.*[Tt][Rr][Aa][Cc][Yy].*' \
  --blocklist-type='TracyCLockCtx' \
  ${COMMON_BINDGEN_PARAMS[@]}

bindgen -o "tracy-client-sys/src/generated_manual_lifetime.rs" \
  --rust-target 1.70.0 \
  --allowlist-function='___tracy_startup_profiler' \
  --allowlist-function='___tracy_shutdown_profiler' \
  ${COMMON_BINDGEN_PARAMS[@]} \
  -DTRACY_MANUAL_LIFETIME

bindgen -o "tracy-client-sys/src/generated_fibers.rs" \
  --rust-target 1.70.0 \
  --allowlist-function='___tracy_fiber_enter' \
  --allowlist-function='___tracy_fiber_leave' \
  ${COMMON_BINDGEN_PARAMS[@]} \
  -DTRACY_FIBERS

# The space after type avoids hitting members called "type".
sed -i 's/pub type /type /g' 'tracy-client-sys/src/generated.rs'

rm -rf "${DESTINATION}"

# Avoid running the other steps if we haven't really updated tracy (e.g. if bindgen/rustfmt version
# changed)
if ! git diff --quiet "tracy-client-sys/tracy"; then
    echo "tracy-changed=true" >> "${GITHUB_OUTPUT:-/dev/stdout}"
else
    exit 0
fi

CURRENT_SYS_VERSION=$(sed -n 's/^version = "\(.*\)" # AUTO-BUMP$/\1/p' tracy-client-sys/Cargo.toml)
CURRENT_CLIENT_VERSION=$(sed -n 's/^version = "\(.*\)" # AUTO-BUMP$/\1/p' tracy-client/Cargo.toml)
CURRENT_TRACING_VERSION=$(sed -n 's/^version = "\(.*\)"$/\1/p' tracing-tracy/Cargo.toml)

SYS_MAJOR=$(echo "$CURRENT_SYS_VERSION" | sed -nr 's,([0-9]+)\.[0-9]+\.[0-9]+,\1,p')
SYS_MINOR=$(echo "$CURRENT_SYS_VERSION" | sed -nr 's,[0-9]+\.([0-9]+)\.[0-9]+,\1,p')
NEXT_SYS_MINOR=$(echo "$SYS_MINOR" | awk '{print $0+1}')
NEXTNEXT_SYS_MINOR=$(echo "$NEXT_SYS_MINOR" | awk '{print $0+1}')
SYS_PATCH=$(echo "$CURRENT_SYS_VERSION" | sed -nr 's,[0-9]+\.[0-9]+\.([0-9]+),\1,p')
CLIENT_MAJOR=$(echo "$CURRENT_CLIENT_VERSION" | sed -nr 's,([0-9]+)\.[0-9]+\.[0-9]+,\1,p')
CLIENT_MINOR=$(echo "$CURRENT_CLIENT_VERSION" | sed -nr 's,[0-9]+\.([0-9]+)\.[0-9]+,\1,p')
CLIENT_PATCH=$(echo "$CURRENT_CLIENT_VERSION" | sed -nr 's,[0-9]+\.[0-9]+\.([0-9]+),\1,p')
NEXT_CLIENT_PATCH=$(echo "$CLIENT_PATCH" | awk '{print $0+1}')

NEXT_SYS_VERSION="$SYS_MAJOR.$NEXT_SYS_MINOR.0"
NEXTNEXT_SYS_VERSION="$SYS_MAJOR.$NEXTNEXT_SYS_MINOR.0"
NEXT_CLIENT_VERSION="$CLIENT_MAJOR.$CLIENT_MINOR.$NEXT_CLIENT_PATCH"

# Adjust the table in the README file…
sed -i "/^<!-- AUTO-UPDATE -->$/i $(printf "| %-6s | %-15s | %-12s | %-13s |" "$TAG" "$NEXT_SYS_VERSION" "$NEXT_CLIENT_VERSION" "$CURRENT_TRACING_VERSION")" \
    README.mkd
# …the version in tracy-client-sys…
sed -i "s/^\(version =\) \".*\" \(# AUTO-BUMP\)$/\1 \"$NEXT_SYS_VERSION\" \2/" \
    tracy-client-sys/Cargo.toml
# …and the versions in tracy-client.
sed -i "s/^\(version =\) \".*\" \(# AUTO-BUMP\)$/\1 \"$NEXT_CLIENT_VERSION\" \2/" \
    tracy-client/Cargo.toml
sed -i "s/^\(version = \".*,\) <.*\" \(# AUTO-UPDATE\)$/\1 <$NEXTNEXT_SYS_VERSION\" \2/" \
    tracy-client/Cargo.toml

# Make a commit that we'll PR
NAME=tracy-client-sys-auto-update[bot]
MAIL="GitHub <noreply@github.com>"
git add tracy-client-sys tracy-client/Cargo.toml README.mkd
git -c user.name="$NAME" -c user.email="$MAIL" commit -m "Update Tracy client bindings to $TAG"
