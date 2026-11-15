#!/bin/bash
# Strip only the staged release copy, before signing. Keep dynamic-library exports: ObjC,
# Swift and vendor framework entry points are runtime interfaces, not disposable symbols.
# MLX Metal kernels and every other resource remain byte-for-byte unchanged.
set -euo pipefail
app=$1
for directory in MacOS Helpers Frameworks; do
  root="$app/Contents/$directory"
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' binary; do
    kind=$(/usr/bin/file -b "$binary")
    case "$kind" in
      *Mach-O*"dynamically linked shared library"*|*Mach-O*"bundle"*)
        /usr/bin/xcrun strip -S -x "$binary" ;;
      *Mach-O*"executable"*)
        if [[ "$directory" == MacOS ]]; then
          # The Swift host loads frameworks/runtime code that may look up exported callbacks.
          # -u -r alone can remove those exports even when dyld needs them at runtime.
          /usr/bin/xcrun strip -S -x "$binary"
        else
          # Owned helpers expose no host callback/plugin ABI. Keep imports/dynamic references.
          /usr/bin/xcrun strip -u -r "$binary"
        fi ;;
      *Mach-O*)
        echo "Unsupported Mach-O in release bundle: $binary ($kind)" >&2
        exit 1 ;;
    esac
  done < <(/usr/bin/find "$root" -type f -print0)
done
