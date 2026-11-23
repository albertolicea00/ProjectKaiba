#!/usr/bin/env bash
# Exports the iOS preset as an Xcode project, then archives it in Release and writes
# <out dir>/<app>-v<version>-<build>-release.ipa.
#
# usage: tools/export_ipa.sh <godot project dir> <app name> [out dir, default builds/ios]
#
# Version and build come from application/short_version and application/version in the iOS
# preset. Signing uses DEVELOPMENT_TEAM from keys/ios.properties (git-ignored), or TEAM=<id>:
# it is written into the preset only for the export and the preset is always restored, so the
# team id never reaches git. IPA_METHOD picks the export: debugging (default for a free personal
# team: your own devices, expires after 7 days), release-testing (Ad Hoc) or app-store-connect
# (default for a paid team).
set -euo pipefail
cd "$(dirname "$0")/.."

project="$1"; app="$2"; out="${3:-builds/ios}"
preset="$project/export_presets.cfg"
godot="${GODOT_BIN:-godot}"
fail() { printf 'export_ipa: %s\n' "$1" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "Xcode is not installed."
team="${TEAM:-$( [ -f keys/ios.properties ] && sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' keys/ios.properties | tail -1 | tr -d '\r' )}"
[ -n "$team" ] || fail "no Apple team: set DEVELOPMENT_TEAM in keys/ios.properties (copy keys/ios.properties.example) or pass TEAM=<id>."

# Reads one option of the preset named "iOS".
ios_option() {
    awk -v key="$1" '
        /^\[preset\.[0-9]+\]$/ { section = $0 }
        /^name="iOS"$/ { target = section; sub(/\]$/, ".options]", target) }
        /^\[/ { current = $0 }
        current == target && index($0, key "=") == 1 { v = substr($0, length(key) + 2); gsub(/"/, "", v); print v; exit }
    ' "$preset"
}
version=$(ios_option application/short_version)
build=$(ios_option application/version)
[ -n "$version" ] && [ -n "$build" ] || fail "no application/short_version or application/version in the iOS preset of $preset."

free=0
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -B1 "teamID = $team;" | grep -q "isFreeProvisioningTeam = 1" && free=1
method="${IPA_METHOD:-$([ "$free" = 1 ] && echo debugging || echo app-store-connect)}"
[ "$free" = 1 ] && [ "$method" != debugging ] && fail "a free personal team can only export IPA_METHOD=debugging."

work=$(mktemp -d)
cp "$preset" "$work/export_presets.cfg.orig"
restore() { cp "$work/export_presets.cfg.orig" "$preset"; rm -rf "$work"; }
trap restore EXIT

# For this export only: the team id, and project-only output so Godot does not sign with its own
# (distribution) settings; xcodebuild signs below.
awk -v team="$team" '
    /^\[preset\.[0-9]+\]$/ { section = $0 }
    /^name="iOS"$/ { target = section; sub(/\]$/, ".options]", target) }
    /^\[/ { current = $0 }
    current == target && index($0, "application/app_store_team_id=") == 1 { $0 = "application/app_store_team_id=\"" team "\"" }
    current == target && index($0, "application/export_project_only=") == 1 { next }
    { print }
    $0 == target { print "application/export_project_only=true" }
' "$work/export_presets.cfg.orig" > "$preset"

echo "Exporting the iOS Xcode project ($version, build $build)"
mkdir -p "$work/xcode"
"$godot" --headless --path "$project" --export-release iOS "$work/xcode/$app.ipa"
xcodeproj=$(find "$work/xcode" -maxdepth 3 -name "*.xcodeproj" | head -1)
[ -n "$xcodeproj" ] || fail "the Godot export has no .xcodeproj."
scheme=$(basename "$xcodeproj" .xcodeproj)

log="$out/xcodebuild.log"
mkdir -p "$out"
echo "Archiving in Release (team $team); log: $log"
xcodebuild -project "$xcodeproj" -scheme "$scheme" -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$work/app.xcarchive" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER="" \
    archive >"$log" 2>&1 || { grep -E "error:" "$log" | sort -u | head -15 >&2; fail "the archive failed; full log: $log"; }

cat >"$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$method</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "Exporting the IPA ($method)"
xcodebuild -exportArchive -archivePath "$work/app.xcarchive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" -allowProvisioningUpdates >>"$log" 2>&1 \
    || { grep -E "error" "$log" | sort -u | tail -10 >&2; fail "the export failed; full log: $log"; }
ipa="$out/$app-v$version-$build-release.ipa"
mv "$work/export/"*.ipa "$ipa"
echo "signed $ipa"
[ "$free" = 1 ] && echo "Personal (free) team: the IPA installs only on your registered devices and stops opening after 7 days."
exit 0
