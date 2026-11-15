#!/bin/bash
# Real Mach-O fixtures, no installed bundle, running app or user terminal involved.
set -euo pipefail
strip_script=$1
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
app="$fixture/Axo with spaces.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources/MLX,Frameworks/Fixture.framework/Versions/A}
cat > "$fixture/library.c" <<'C'
extern int host_callback(void);
__attribute__((noinline)) static int private_function(void) { return 11; }
int public_api(void) { return private_function() + host_callback(); }
int unused_public_api(void) { return 99; }
C
cat > "$fixture/main.c" <<'C'
extern int public_api(void);
__attribute__((noinline)) static int private_main(void) { return 7; }
int host_callback(void) { return private_main(); }
int main(void) { return public_api() == 18 ? 0 : 1; }
C
library="$app/Contents/Frameworks/Fixture.framework/Versions/A/Fixture"
xcrun clang -g -O0 -c "$fixture/library.c" -o "$fixture/library.o"
xcrun clang -dynamiclib "$fixture/library.o" -undefined dynamic_lookup -o "$library" -install_name "$library"
xcrun clang -g -O0 -c "$fixture/main.c" -o "$fixture/main.o"
xcrun clang "$fixture/main.o" "$library" -o "$app/Contents/MacOS/Axo"
printf '__attribute__((noinline)) static int private_helper(void) { return 3; }\nint main(void) { return private_helper() == 3 ? 0 : 1; }\n' > "$fixture/helper.c"
xcrun clang -O0 "$fixture/helper.c" -o "$app/Contents/Helpers/helper with spaces"
cp "$app/Contents/MacOS/Axo" "$fixture/outside"
ln -s "$fixture/outside" "$app/Contents/Helpers/outside-link"
ln -s A "$app/Contents/Frameworks/Fixture.framework/Versions/Current"
printf 'not a Mach-O; retain all GPU kernels\n' > "$app/Contents/Resources/MLX/mlx.metallib"
cp "$app/Contents/Resources/MLX/mlx.metallib" "$fixture/resource-before"
cp "$fixture/outside" "$fixture/outside-before"
xcrun nm "$library" > "$fixture/before-symbols"
grep -q ' t _private_function' "$fixture/before-symbols"
"$app/Contents/MacOS/Axo"
/bin/bash "$strip_script" "$app"
xcrun nm "$library" > "$fixture/after-symbols"
! grep -q ' t _private_function' "$fixture/after-symbols"
grep -q ' T _public_api' "$fixture/after-symbols"
grep -q ' T _unused_public_api' "$fixture/after-symbols"
xcrun nm "$app/Contents/MacOS/Axo" > "$fixture/app-symbols"
! grep -q ' t _private_main' "$fixture/app-symbols"
grep -q ' T _host_callback' "$fixture/app-symbols"
xcrun nm "$app/Contents/Helpers/helper with spaces" > "$fixture/helper-symbols"
! grep -q '_private_helper' "$fixture/helper-symbols"
# arm64 linkers ad-hoc sign their output; stripping invalidates that seal.
# Execute only after the same strip-then-sign order used by release packaging.
cmp "$fixture/resource-before" "$app/Contents/Resources/MLX/mlx.metallib"
cmp "$fixture/outside-before" "$fixture/outside"
# A second pass must remain valid, and staged nested code can still be sealed afterward.
/bin/bash "$strip_script" "$app"
codesign --force --sign - "$library"
codesign --force --sign - "$app/Contents/MacOS/Axo"
codesign --force --sign - "$app/Contents/Helpers/helper with spaces"
codesign --verify --strict "$library"
codesign --verify --strict "$app/Contents/MacOS/Axo"
"$app/Contents/MacOS/Axo"
"$app/Contents/Helpers/helper with spaces"
mkdir -p "$fixture/unsupported.app/Contents/Helpers"
cp "$fixture/main.o" "$fixture/unsupported.app/Contents/Helpers/object"
if /bin/bash "$strip_script" "$fixture/unsupported.app" > "$fixture/refused" 2>&1; then
  echo "FAIL: unexpected Mach-O kind was silently accepted" >&2; exit 1
fi
grep -q "Unsupported Mach-O" "$fixture/refused"
echo 'ok: executable stripping, retained framework exports/callbacks, untouched resources/symlinks, repeat pass and post-strip signing'
