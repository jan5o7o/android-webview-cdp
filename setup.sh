#!/data/data/com.termux/files/usr/bin/bash
# setup.sh — take a fresh Android phone + Termux from nothing to a verified, working
# so7o-android-webview-shell. Idempotent: safe to run again at any time.
#
#   bash ./setup.sh --pre-install-checkup   READ-ONLY: reports what is missing and what to do
#   bash ./setup.sh                        install what is missing, build, install, verify
#   bash ./setup.sh --build                stop after building the APK
#   bash ./setup.sh --no-verify            skip the launch + CDP check
#
# Run it as `bash ./setup.sh`: the shebang is a Termux path, which keeps the same
# command working if you are on a laptop instead.
#
# Sequence for a fresh phone:
#   1. Termux (from F-Droid or GitHub releases — the Play Store build is stale)
#   2. gh repo clone jan5o7o/android-webview-cdp   &&  cd android-webview-cdp
#   3. bash ./setup.sh --pre-install-checkup     # writes nothing; says what to fix
#   4. bash ./setup.sh                           # then build + install + verify
#
# What it CANNOT do — these need your hands on the phone, and it tells you so:
#   * enable Developer options / Wireless debugging, and the one-time `adb pair`
# Everything else it handles, including the traps: a missing `zip`, a platform jar that
# was never downloaded, a missing signing password, and the signature clash from a fresh
# checkout.
#
# Off-device (laptop + USB): run as `bash setup.sh` — this shebang is a Termux path.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

PKG=app.so7o.webview
ACTIVITY="$PKG/.MainActivity"
JAR_REL="sdk/platforms/android-36/android.jar"
JAR_URL="https://dl.google.com/android/repository/platform-36_r02.zip"
ADB="${ADB:-adb}"

MODE=full
case "${1:-}" in
  --pre-install-checkup|--check) MODE=check ;;
  --build) MODE=build ;;
  --no-verify) MODE=noverify ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option '$1' (try --help)" >&2; exit 1 ;;
esac

FAILED=0
NEXT=()
if [ -t 1 ]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_RST=$'\033[0m'; else C_OK=''; C_WARN=''; C_BAD=''; C_RST=''; fi
ok()   { printf '  %sok%s    %s\n' "$C_OK" "$C_RST" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$C_WARN" "$C_RST" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n' "$C_BAD" "$C_RST" "$1"; FAILED=1; }
fix()  { NEXT+=("$1"); }
info() { printf '        %s\n' "$1"; }
step() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------- 1. the device
step "device"
SDK="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
REL="$(getprop ro.build.version.release 2>/dev/null || echo '?')"
MODEL="$(getprop ro.product.model 2>/dev/null || echo '?')"
if [ "${SDK:-0}" -ge 34 ] 2>/dev/null; then
    ok "Android $REL (API $SDK) on $MODEL"
else
    warn "Android $REL (API $SDK) on $MODEL — the keep-alive service uses foregroundServiceType=specialUse, which needs API 34+. Expect trouble below 14."
fi
if command -v termux-setup-storage >/dev/null 2>&1; then
    ok "running in Termux"
else
    bad "not Termux (\$PREFIX=$PREFIX) — this project is built and installed from Termux on the device"
    fix "install Termux from F-Droid or GitHub releases (not the Play Store), then re-clone there"
fi

# ---------------------------------------------------------------- 2. tools
step "build tools"
declare -A PKG_FOR=(
  [aapt2]=aapt2 [d8]=d8 [apksigner]=apksigner [javac]=openjdk-21 [keytool]=openjdk-21
  [adb]=android-tools [node]=nodejs-lts [python3]=python3 [zip]=zip [unzip]=unzip [curl]=curl
)
MISSING_CMDS=(); MISSING_PKGS=()
for c in aapt2 d8 apksigner javac keytool adb node python3 zip unzip curl; do
    if command -v "$c" >/dev/null 2>&1; then
        case "$c" in javac|keytool) ok "$c ($(javac -version 2>&1 | awk '{print $2}'))";; *) ok "$c";; esac
    else
        MISSING_CMDS+=("$c")
        MISSING_PKGS+=("${PKG_FOR[$c]}")
    fi
done
if [ "${#MISSING_CMDS[@]}" -gt 0 ]; then
    # unique packages
    UNIQ_PKGS="$(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u | tr '\n' ' ')"
    if [ "$MODE" = check ]; then
        bad "missing: ${MISSING_CMDS[*]}"
        fix "pkg install $UNIQ_PKGS"
    else
        warn "missing: ${MISSING_CMDS[*]} — installing: $UNIQ_PKGS"
        if pkg install -y $UNIQ_PKGS; then
            ok "installed $UNIQ_PKGS"
        else
            bad "pkg install failed — run it by hand: pkg install $UNIQ_PKGS"
        fi
    fi
fi
if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    [ "${NODE_MAJOR:-0}" -ge 22 ] 2>/dev/null || { bad "node $NODE_MAJOR is too old — cdp.mjs needs 22+ for the built-in WebSocket"; fix "pkg install nodejs-lts"; }
fi

# ---------------------------------------------------------------- 3. platform jar
step "android platform jar"
if [ -f "$JAR_REL" ]; then
    ok "$JAR_REL ($(du -h "$JAR_REL" | cut -f1))"
elif [ "$MODE" = check ]; then
    bad "$JAR_REL missing (27 MB platform jar, deliberately not in the repo)"
    fix "curl -LO $JAR_URL && unzip -j platform-36_r02.zip android-36/android.jar -d sdk/platforms/android-36/"
else
    info "downloading $JAR_URL (~27 MB)"
    if curl -L --fail -o platform-36_r02.zip "$JAR_URL" \
       && mkdir -p sdk/platforms/android-36 \
       && unzip -o -j platform-36_r02.zip android-36/android.jar -d sdk/platforms/android-36/ >/dev/null \
       && rm -f platform-36_r02.zip; then
        ok "extracted to $JAR_REL ($(du -h "$JAR_REL" | cut -f1))"
    else
        bad "download/extract failed — fetch $JAR_URL by hand (see README)"
    fi
fi

# ---------------------------------------------------------------- 4. signing password
step "keystore password"
KSFILE="$HOME/.so7o-webview-kspass"
if [ -n "${KSPASS:-}" ]; then
    ok "KSPASS set in the environment"
elif [ -f "$KSFILE" ]; then
    ok "$KSFILE present"
elif [ -f keystore.jks ]; then
    # the password is whatever this key was created with; it cannot be invented
    bad "keystore.jks exists but its password is not available — build.sh fails closed"
    fix "printf %s 'the-password' > $KSFILE && chmod 600 $KSFILE   # must match the existing key"
else
    bad "no signing password, so build.sh can neither create nor use a keystore"
    fix "pick one: printf %s 'some-password' > $KSFILE && chmod 600 $KSFILE   # a new key is generated"
fi

# ---------------------------------------------------------------- 5. adb
step "adb"
if [ "$MODE" = build ]; then
    info "not needed for --build (skipped)"
elif ! command -v "${ADB%% *}" >/dev/null 2>&1; then
    bad "${ADB%% *} not on PATH"
    fix "pkg install android-tools"
elif "$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
    ok "connected: $("$ADB" devices | awk 'NR>1 && $2=="device"{printf "%s ", $1}')"
else
    bad "no device connected"
    fix "$ADB pair <ip>:<pair-port>     # once per device; the code is on the Wireless debugging screen"
    fix "$ADB connect <ip>:<connect-port>   # changes every time Wireless debugging is toggled; 127.0.0.1:<port> works on-device"
    info "On the phone: Settings → About phone → tap Build number 7× →"
    info "Developer options → Wireless debugging → on → 'Pair device with pairing code'."
    [ "$MODE" = check ] || info "(continuing — build does not need adb)"
fi

# ---------------------------------------------------------------- 6. build
step "build"
if [ "$MODE" = check ]; then
    info "skipped (--check)"
elif bash build.sh; then
    ok "out/so7o-webview.apk ($(du -h out/so7o-webview.apk | cut -f1))"
else
    bad "build.sh failed — see the output above"
fi

[ "$MODE" = build ] && { printf '\n'; [ "$FAILED" = 0 ] && echo "built." || echo "problems above."; exit "$FAILED"; }

# ---------------------------------------------------------------- 7. install
step "install"
if [ "$MODE" = check ]; then
    info "skipped (--check)"
elif ! "$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
    bad "no device — cannot install"
else
    OUT="$("$ADB" install -r out/so7o-webview.apk 2>&1)"
    if printf '%s' "$OUT" | grep -q "Success"; then
        ok "installed"
    elif printf '%s' "$OUT" | grep -qiE "UPDATE_INCOMPATIBLE|signatures do not match"; then
        # fresh checkout ⇒ fresh signing key ⇒ cannot update someone else's build
        warn "signed differently from the installed copy (no keystore is committed) — uninstalling and reinstalling"
        "$ADB" uninstall "$PKG" >/dev/null 2>&1
        OUT="$("$ADB" install -r out/so7o-webview.apk 2>&1)"
        printf '%s' "$OUT" | grep -q "Success" && ok "installed (after uninstall)" || bad "install failed: $OUT"
    else
        bad "install failed: $OUT"
    fi
    # the notification belongs to the keep-alive service; granting it keeps the FGS visible
    "$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 \
        && ok "notification permission granted" || info "notification permission not granted (optional)"
fi

# ---------------------------------------------------------------- 8. launch + verify
step "launch and verify"
if [ "$MODE" = check ]; then
    info "skipped (--check)"
elif ! "$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
    bad "no device — cannot verify"
else
    "$ADB" shell am start -n "$ACTIVITY" >/dev/null 2>&1 || true
    UP=no
    for _ in $(seq 1 20); do
        if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:9334/json/version 2>/dev/null)" = "200" ]; then UP=yes; break; fi
        sleep 0.5
    done
    if [ "$UP" = yes ]; then
        ok "relay answering on 127.0.0.1:9334 (no adb forward needed)"
        TITLE="$(node cdp.mjs 'document.title' 2>/dev/null | tail -1)"
        if [ "$TITLE" = "So7o Android Webview Shell" ]; then
            ok "CDP round-trip: document.title = \"$TITLE\""
            BEFORE="$(node cdp.mjs '__so7o.taps()' 2>/dev/null | tail -1)"
            node cdp.mjs --click 'text=tap me' >/dev/null 2>&1
            AFTER="$(node cdp.mjs '__so7o.taps()' 2>/dev/null | tail -1)"
            if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$AFTER" -eq "$((BEFORE + 1))" ] 2>/dev/null; then
                ok "input injection: taps $BEFORE → $AFTER"
            else
                warn "input injection: taps $BEFORE → $AFTER (expected +1)"
            fi
            # A real network site at phone size — the point of the whole arrangement. The
            # bundled page above only proves the WebView works; this proves the pipeline
            # drives the open web at a mobile viewport and can read the result back.
            node cdp.mjs --nav https://news.ycombinator.com/news --wait body >/dev/null 2>&1 || true
            HN="$(node cdp.mjs --nav https://news.ycombinator.com/news --wait '.titleline' \
                  'JSON.stringify({title:document.title,stories:document.querySelectorAll(".titleline > a").length})' 2>/dev/null | tail -1)"
            case "$HN" in
                *'"title":"Hacker News"'*) ok "real site: news.ycombinator.com/news ($HN)" ;;
                *) warn "Hacker News front page gave: ${HN:-<no response>}" ;;
            esac

            VIS="$(node cdp.mjs 'document.visibilityState' 2>/dev/null | tail -1)"
            if [ "$VIS" = "visible" ]; then
                node cdp.mjs --shot setup-check.png >/dev/null 2>&1 \
                    && ok "screenshot: setup-check.png (phone-sized capture of that page)" \
                    || warn "screenshot failed although the page reports visible"
            else
                warn "screenshot not attempted: page is '$VIS', so there are no frames to capture"
                info "pixels need a visible window — ./display.sh overlay gives one off-screen"
            fi
            # leave the app on its own page rather than someone else's website
            node cdp.mjs --nav file:///android_asset/index.html >/dev/null 2>&1 || true
        else
            bad "CDP answered but document.title was '$TITLE'"
        fi
    else
        bad "relay not answering — is the app running? adb logcat -s So7oWebViewRelay"
    fi
fi

# ---------------------------------------------------------------- summary
printf '\n'
if [ "${#NEXT[@]}" -gt 0 ]; then
    echo "Do this next:"
    i=0
    for n in "${NEXT[@]}"; do i=$((i + 1)); printf '  %d. %s\n' "$i" "$n"; done
    printf '\n'
fi
if [ "$MODE" = check ]; then
    if [ "$FAILED" = 0 ]; then
        echo "Pre-install checkup passed — nothing to fix. Now run: bash ./setup.sh"
    else
        echo "Not ready. Fix the items above, then re-run: bash ./setup.sh --pre-install-checkup"
    fi
elif [ "$FAILED" = 0 ]; then
    echo "Ready. Next:"
    echo "  ./display.sh overlay          # run it off-screen on a simulated phone display"
    echo "  node cdp.mjs --repl           # drive it interactively"
else
    echo "Not ready — fix the FAIL lines above. See README → Prerequisites."
fi
exit "$FAILED"
