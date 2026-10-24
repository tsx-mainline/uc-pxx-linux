#!/bin/sh
# Host test for ci/build-kernel.sh. It does not build a kernel and needs no
# network. It checks the pin, the required initramfs input, the config
# fragment and the device trees.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
S=$HERE/ci/build-kernel.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

echo "== the pin =="
rev=$(grep -v '^#' "$HERE/kernel/KERNEL_REV.lts" | head -n 1 | tr -d ' \n')
case $rev in
*[!0-9a-f]*|"") bad "KERNEL_REV.lts is not 40 hex digits";;
*) [ ${#rev} = 40 ] && ok "KERNEL_REV.lts has a 40 digit hash" || bad "KERNEL_REV.lts is not 40 hex digits";;
esac
case $rev in *[!0]*) ok "the pin is not the placeholder";; *) bad "the pin is all zeros";; esac

echo "== the build input =="
mkdir "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/aarch64-linux-gnu-gcc"; chmod +x "$T/bin/aarch64-linux-gnu-gcc"
out=$(PATH="$T/bin:$PATH" bash "$S" --flavor lts --src "$T/src" 2>&1) && bad "no --initramfs must fail" || ok "no --initramfs: error"
case $out in *"--initramfs FILE is required"*) ok "the error names --initramfs";; *) bad "unclear error: $out";; esac
out=$(PATH="$T/bin:$PATH" bash "$S" --flavor lts --src "$T/src" --initramfs "$T/none.cpio" 2>&1) && bad "a missing cpio must fail" || ok "missing cpio file: error"
case $out in *"no initramfs"*) ok "the error names the file";; *) bad "unclear error: $out";; esac

echo "== the fragment and the device trees =="
grep -q 'defconfig uc-pxx.config' "$S" && ok "the config fragment is uc-pxx.config" || bad "no uc-pxx.config"
grep -q 'INITRAMFS_SOURCE' "$S" && grep -q 'INITRAMFS_COMPRESSION_XZ' "$S" && ok "the script sets the initramfs source and xz" || bad "no initramfs config"
for d in rk3399-crestron-ucp10.dtb rk3399-crestron-ucp8.dtb; do
	grep -q "$d" "$S" && ok "builds $d" || bad "does not build $d"
done
echo "$N ok, $F failed"
[ "$F" = 0 ]
