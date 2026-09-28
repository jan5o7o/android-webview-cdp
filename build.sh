#!/data/data/com.termux/files/usr/bin/bash
# Hand-rolled Android build for Termux/aarch64.
# No Gradle, no Android SDK install: aapt2 -> javac -> d8 -> alignment check -> apksigner.
# No aidl, no external jars, and assets/ is linked in (-A).
# aapt2 -> javac -> d8 -> package -> alignment check -> apksigner
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ANDROID_JAR="$ROOT/sdk/platforms/android-36/android.jar"
[ -f "$ANDROID_JAR" ] || {
  echo "missing $ANDROID_JAR (27 MB, deliberately not in the repo)." >&2
  echo "Get it with:  ./setup.sh    — or by hand:" >&2
  echo "  curl -LO https://dl.google.com/android/repository/platform-36_r02.zip" >&2
  echo "  unzip -j platform-36_r02.zip android-36/android.jar -d sdk/platforms/android-36/" >&2
  exit 1
}

BUILD="$ROOT/build"
OUT="$ROOT/out"
KS="$ROOT/keystore.jks"
# Signing key password.
#
# Deliberately NOT stored in this file, because this file is committed: a hardcoded
# password here is public the moment the keystore leaks (a home-dir zip, a device
# backup), and there would be no second factor to fall back on. Provide it either in
# the environment or in a file outside the repo:
#
#   KSPASS=... ./build.sh
#   printf %s 'the-password' > ~/.so7o-webview-kspass && chmod 600 ~/.so7o-webview-kspass
#
KSFILE="$HOME/.so7o-webview-kspass"
if [ -z "${KSPASS:-}" ] && [ -f "$KSFILE" ]; then
  KSPASS="$(cat "$KSFILE")"
fi
KSPASS="${KSPASS:?set KSPASS in the environment, or create $KSFILE containing it}"
MIN_SDK=30
TARGET_SDK=36
VERSION_CODE="${VERSION_CODE:-4}"
VERSION_NAME="${VERSION_NAME:-0.4}"

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD/res" "$BUILD/classes" "$BUILD/gen" "$BUILD/dex" "$OUT"

echo "==> 1/5 aapt2 compile"
aapt2 compile --dir "$ROOT/res" -o "$BUILD/res.zip"

echo "==> 2/5 aapt2 link (+assets)"
aapt2 link \
  -o "$BUILD/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$ROOT/AndroidManifest.xml" \
  --java "$BUILD/gen" \
  -A "$ROOT/assets" \
  --min-sdk-version "$MIN_SDK" \
  --target-sdk-version "$TARGET_SDK" \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
  "$BUILD/res.zip"

echo "==> 3/5 javac"
find "$ROOT/java" "$BUILD/gen" -name '*.java' > "$BUILD/sources.txt"
javac \
  -source 8 -target 8 \
  -bootclasspath "$ANDROID_JAR" \
  -encoding UTF-8 \
  -nowarn \
  -d "$BUILD/classes" \
  @"$BUILD/sources.txt" 2>&1 | grep -viE "bootstrap class path|source value 8|target value 8|deprecat" || true
[ -d "$BUILD/classes/app/so7o/webview" ] || { echo "javac produced no classes"; exit 1; }

echo "==> 4/5 d8"
find "$BUILD/classes" -name '*.class' > "$BUILD/inputs.txt"
d8 --lib "$ANDROID_JAR" --min-api "$MIN_SDK" --output "$BUILD/dex" @"$BUILD/inputs.txt"

cp "$BUILD/base.apk" "$OUT/so7o-webview-unsigned.apk"
cd "$BUILD/dex" && zip -q -X "$OUT/so7o-webview-unsigned.apk" classes.dex
cd "$ROOT"

echo "==> 4b/5 alignment report"
python3 - "$OUT/so7o-webview-unsigned.apk" <<'PY'
import sys, zipfile, struct
p = sys.argv[1]
z = zipfile.ZipFile(p)
bad = []
for i in z.infolist():
    with open(p, 'rb') as f:
        f.seek(i.header_offset)
        raw = f.read(30)
        if raw[:4] != b'PK\x03\x04':
            bad.append((i.filename, 'bad-local-header')); continue
        nlen, elen = struct.unpack('<HH', raw[26:30])
        data_off = i.header_offset + 30 + nlen + elen
    stored = i.compress_type == zipfile.ZIP_STORED
    ok = (data_off % 4 == 0) if stored else True
    print(f"   {i.filename:30} {'STORED' if stored else 'DEFLATE':8} off={data_off:8} align4={'OK' if ok else 'BAD'}")
    if stored and not ok:
        bad.append((i.filename, f'offset {data_off} not 4-aligned'))
if bad:
    print('   !! alignment problems:', bad); sys.exit(1)
print('   alignment OK (all STORED entries 4-byte aligned)')
PY

echo "==> 5/5 sign"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -v -keystore "$KS" -storepass "$KSPASS" -keypass "$KSPASS" \
    -alias so7o -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=So7o Android Webview, OU=dev, O=local, L=., S=., C=US" >/dev/null 2>&1
  echo "    generated $KS"
fi
apksigner sign \
  --ks "$KS" --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" \
  --v1-signing-enabled true --v2-signing-enabled true \
  --out "$OUT/so7o-webview.apk" "$OUT/so7o-webview-unsigned.apk"

apksigner verify --print-certs "$OUT/so7o-webview.apk" | head -4
echo
echo "APK: $OUT/so7o-webview.apk  ($(du -h "$OUT/so7o-webview.apk" | cut -f1))"
