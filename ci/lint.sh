#!/bin/bash
# Syntax and smoke lint for the whole repo. It needs no hardware and no build.
# Run it locally the same way as CI does: ci/lint.sh
#   - A script with a "#!/bin/sh" shebang must pass `busybox sh -n` when
#     busybox is available (the shell on the panel), else `sh -n`.
#   - A script with a "#!/bin/bash" shebang must pass `bash -n`.
#   - Every *.py file must byte-compile.
#   - Relative doc links and anchors must resolve.
#   - Every file in a bin or init.d folder of the overlay must be executable.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
SH="sh -n"
command -v busybox >/dev/null && SH="busybox sh -n"

sh_files=() bash_files=() openrc_files=()
while IFS= read -r -d '' f; do
	case "$(head -c 4096 "$f" 2>/dev/null | tr -d '\0' | head -n1)" in
	'#!/bin/sh') sh_files+=("$f");;
	'#!/bin/bash') bash_files+=("$f");;
	'#!/sbin/openrc-run') openrc_files+=("$f");;
	esac
done < <(find . -type f -not -path './.git/*' -print0)

echo "== $SH (${#sh_files[@]} scripts) =="
for f in "${sh_files[@]}"; do
	$SH "$f" || { echo "FAIL: $SH $f"; fail=1; }
done

# An OpenRC script is shell code. Check it with the same shell.
echo "== $SH on OpenRC scripts (${#openrc_files[@]} scripts) =="
for f in "${openrc_files[@]}"; do
	$SH "$f" || { echo "FAIL: $SH $f"; fail=1; }
done

echo "== bash -n (${#bash_files[@]} scripts) =="
for f in "${bash_files[@]}"; do
	bash -n "$f" || { echo "FAIL: bash -n $f"; fail=1; }
done

echo "== python3 -m py_compile =="
while IFS= read -r f; do
	python3 -I -m py_compile "$f" || { echo "FAIL: py_compile $f"; fail=1; }
done < <(find . -name '*.py' -not -path './.git/*')
find . -name __pycache__ -not -path './.git/*' -exec rm -rf {} + 2>/dev/null

echo "== docs: relative links and anchors resolve =="
python3 ci/check-doc-links.py || { echo "FAIL: doc links"; fail=1; }

echo "== overlay programs and services are executable =="
for f in rootfs/overlay/usr/local/sbin/* rootfs/overlay/usr/local/bin/* rootfs/overlay/etc/init.d/* \
	packages/*/root/usr/local/sbin/* packages/*/root/usr/local/bin/* packages/*/root/etc/init.d/*; do
	[ -e "$f" ] || continue
	[ -x "$f" ] || { echo "FAIL: $f is not executable"; fail=1; }
done

[ $fail -eq 0 ] && echo "lint OK" || echo "lint FAILED"
exit $fail
