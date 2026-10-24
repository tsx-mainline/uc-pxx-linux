#!/bin/sh
# Check that a local copy of the published apk tree has the packages that the
# image build installs by name (docs/rootfs.md "Where the packages come from").
#
#   rootfs/check-apk-tree.sh TREE [PROFILE]
#
# TREE holds <ALPINE>/common/<ARCH> and <ALPINE>/uc-pxx/<ARCH>, each with an
# APKINDEX.tar.gz. PROFILE is console, kiosk or ha (default ha). The script
# looks for these names in the two indexes:
#   - the board package uc-pxx-board
#   - the profile meta package uc-pxx-<PROFILE>
#   - the packages of packages-tsx.txt that the profile installs
# It prints each missing name and exits with status 1. It exits with status 0
# when the tree has all of them and prints only the summary line.
# The board package and the profile meta packages are private. The published
# tree has the common packages and the kernel package of the uc-pxx. So a tree
# from the public URL alone lacks them. Add the files of these packages to
# <TREE>/<ALPINE>/uc-pxx/<ARCH> and index the folder (tsx-aports
# scripts/index.sh).
# ALPINE (default v3.24) and ARCH (default aarch64) pick the folders.
# The script needs tar and awk.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=${1:-}
PROFILE=${2:-ha}
[ -n "$TREE" ] || { sed -n '2,22p' "$0" >&2; exit 2; }
ALPINE=${ALPINE:-v3.24}
ARCH=${ARCH:-aarch64}
T=$(mktemp -d "${TMPDIR:-/tmp}/check-apk-tree.XXXXXX"); trap 'rm -rf "$T"' EXIT

: > "$T/have"
for c in common uc-pxx; do
	idx=$TREE/$ALPINE/$c/$ARCH/APKINDEX.tar.gz
	if [ -r "$idx" ]; then
		tar -xzOf "$idx" APKINDEX | awk '/^P:/ { print substr($0, 3) }' >> "$T/have"
	else
		echo "check-apk-tree: no $ALPINE/$c/$ARCH/APKINDEX.tar.gz under $TREE" >&2
	fi
done

{
	echo uc-pxx-board
	echo "uc-pxx-$PROFILE"
	sh "$HERE/profile.sh" packages "$PROFILE" "$HERE/packages-tsx.txt" | sed 's/=.*//'
} | sort -u > "$T/want"

sort -u "$T/have" | comm -13 - "$T/want" > "$T/missing"
if [ -s "$T/missing" ]; then
	echo "check-apk-tree: the tree $TREE lacks these packages for the $PROFILE image:" >&2
	sed 's/^/  /' "$T/missing" >&2
	exit 1
fi
echo "check-apk-tree: the tree has all $(wc -l < "$T/want" | tr -d ' ') packages that the $PROFILE image names"
