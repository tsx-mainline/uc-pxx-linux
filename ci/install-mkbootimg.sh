#!/bin/bash
# Install the AOSP mkbootimg at a pinned revision for kernel/mkimage.sh.
#
#   ci/install-mkbootimg.sh DIR
#
# The mkbootimg package of Ubuntu 24.04 does not run: it lacks its gki
# module and stops with a Python error. This script gets the AOSP source
# (platform/system/tools/mkbootimg) at MKBOOTIMG_REV into DIR/src and writes
# the command DIR/bin/mkbootimg. Add DIR/bin to PATH. In a GitHub workflow,
# the script does this itself through GITHUB_PATH.
#
# Host packages: git, python3. Nothing is compiled.
set -euo pipefail
DIR=${1:?usage: ci/install-mkbootimg.sh DIR}
URL=https://android.googlesource.com/platform/system/tools/mkbootimg
# main of 2025-03-02 ("Cleanup python version properties")
MKBOOTIMG_REV=${MKBOOTIMG_REV:-d2bb0af5ba6d3198a3e99529c97eda1be0b5a093}

mkdir -p "$DIR/bin"
DIR=$(cd "$DIR" && pwd)
rm -rf "$DIR/src"
git init -q "$DIR/src"
git -C "$DIR/src" fetch -q --depth 1 "$URL" "$MKBOOTIMG_REV"
git -C "$DIR/src" checkout -q FETCH_HEAD
[ "$(git -C "$DIR/src" rev-parse HEAD)" = "$MKBOOTIMG_REV" ] ||
	{ echo "install-mkbootimg: the checkout is not at $MKBOOTIMG_REV" >&2; exit 1; }
printf '#!/bin/sh\nexec python3 %s/src/mkbootimg.py "$@"\n' "$DIR" > "$DIR/bin/mkbootimg"
chmod 755 "$DIR/bin/mkbootimg"
"$DIR/bin/mkbootimg" --help >/dev/null ||
	{ echo "install-mkbootimg: $DIR/bin/mkbootimg does not run" >&2; exit 1; }
[ -z "${GITHUB_PATH:-}" ] || echo "$DIR/bin" >> "$GITHUB_PATH"
echo "mkbootimg $MKBOOTIMG_REV: $DIR/bin/mkbootimg"
