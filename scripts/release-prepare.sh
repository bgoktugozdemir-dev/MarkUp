#!/bin/bash
# Produces reviewable signed assets only. It never creates a GitHub Release or publishes a feed.
set -euo pipefail
umask 077
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

python3 - <<'PY'
import base64, os, re
from urllib.parse import urlsplit
required = ['RELEASE_ENABLED','RELEASE_REPOSITORY','DEVELOPMENT_TEAM','DEVELOPER_ID_APPLICATION',
            'MARKUP_UPDATE_FEED','MARKUP_UPDATE_PUBLIC_KEY','MARKUP_DOWNLOAD_URL_PREFIX','RELEASE_VERSION_TAG',
            'RELEASE_BUILD_NUMBER','CERTIFICATE_P12_BASE64','CERTIFICATE_P12_PASSWORD','NOTARY_API_KEY_BASE64',
            'NOTARY_KEY_ID','NOTARY_ISSUER_ID','SPARKLE_PRIVATE_KEY']
missing = [name for name in required if not os.environ.get(name)]
if missing: raise SystemExit('Owner setup required; missing: ' + ', '.join(missing) + '. See docs/OWNER_SETUP_TR.md.')
def require(value, message):
    if not value: raise SystemExit(message)
require(os.environ['RELEASE_ENABLED']=='true', 'Set RELEASE_ENABLED=true only after protecting the release environment.')
require(re.fullmatch(r'[\w.-]+/[\w.-]+', os.environ['RELEASE_REPOSITORY']), 'RELEASE_REPOSITORY must be the confirmed owner/repository.')
if os.environ.get('GITHUB_ACTIONS') == 'true':
    require(os.environ['GITHUB_REPOSITORY']==os.environ['RELEASE_REPOSITORY'], 'Repository does not match the approved release repository.')
    require(os.environ.get('GITHUB_REF')=='refs/tags/'+os.environ['RELEASE_VERSION_TAG'], 'Only reviewed version tags can sign.')
require(re.fullmatch(r'v\d+\.\d+\.\d+', os.environ['RELEASE_VERSION_TAG']), 'Use a vMAJOR.MINOR.PATCH tag.')
require(re.fullmatch(r'[1-9]\d*', os.environ['RELEASE_BUILD_NUMBER']), 'RELEASE_BUILD_NUMBER must be a positive monotonic integer.')
require(re.fullmatch(r'[A-Z0-9]{10}', os.environ['DEVELOPMENT_TEAM']), 'DEVELOPMENT_TEAM must be the ten-character Team ID.')
require(os.environ['DEVELOPER_ID_APPLICATION'].startswith('Developer ID Application: ') and '\n' not in os.environ['DEVELOPER_ID_APPLICATION'], 'Select the full Developer ID Application signing identity.')
for name in ['MARKUP_UPDATE_FEED','MARKUP_DOWNLOAD_URL_PREFIX']:
    url=urlsplit(os.environ[name])
    require(url.scheme=='https' and url.hostname and not url.username and not url.password and not url.query and not url.fragment,
            name+' must be a public HTTPS URL without credentials, query, or fragment.')
    require(not url.hostname.endswith(('.invalid','.example')) and url.hostname not in ('example.com','example.org'), name+' still contains a development placeholder.')
try:
    require(len(base64.b64decode(os.environ['MARKUP_UPDATE_PUBLIC_KEY'],validate=True))==32, 'Sparkle public key must decode to 32 bytes.')
    require(len(base64.b64decode(os.environ['SPARKLE_PRIVATE_KEY'].strip(),validate=True)) in (32,96), 'Sparkle private export must decode to a supported 32-byte seed or legacy 96-byte pair.')
    require(len(base64.b64decode(''.join(os.environ['CERTIFICATE_P12_BASE64'].split()),validate=True))>100, 'Invalid certificate export.')
    require(b'PRIVATE KEY' in base64.b64decode(''.join(os.environ['NOTARY_API_KEY_BASE64'].split()),validate=True), 'Invalid notarization API key export.')
except (ValueError, TypeError): raise SystemExit('A signing secret is malformed base64; secret values are intentionally not printed.')
require(re.fullmatch(r'[A-Za-z0-9]{10,}', os.environ['NOTARY_KEY_ID']), 'Invalid notary API Key ID.')
require(re.fullmatch(r'[a-fA-F0-9-]{36}', os.environ['NOTARY_ISSUER_ID']), 'Use a Team API key with its Issuer UUID.')
print('Owner configuration preflight passed. No credentials have been imported.')
PY
if [[ "${1:-}" == "--preflight" ]]; then exit 0; fi
if [[ $# -ne 0 ]]; then printf '%s\n' 'Usage: release-prepare.sh [--preflight]' >&2; exit 2; fi

python3 scripts/release-check.py
task_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/markup-release.XXXXXX")"
keychain_path="$task_dir/signing.keychain-db"
original_keychains=()
while IFS= read -r entry; do original_keychains+=("$entry"); done < <(security list-keychains -d user | python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))')
cleanup() {
    local result=$?
    trap - EXIT INT TERM
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    rm -rf "$task_dir"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
keychain_password="$(openssl rand -hex 32)"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then printf '::add-mask::%s\n' "$keychain_password"; fi
export MARKUP_RELEASE_TASK_DIR="$task_dir"
python3 - <<'PY'
import base64,os,plistlib
from pathlib import Path
p=Path(os.environ['MARKUP_RELEASE_TASK_DIR'])
for env,name in [('CERTIFICATE_P12_BASE64','certificate.p12'),('NOTARY_API_KEY_BASE64','notary.p8')]:
    (p/name).write_bytes(base64.b64decode(''.join(os.environ[env].split()),validate=True))
(p/'sparkle-private').write_text(os.environ['SPARKLE_PRIVATE_KEY'].strip())
template=plistlib.loads(Path('Config/ExportOptions.plist.template').read_bytes())
template['teamID']=os.environ['DEVELOPMENT_TEAM']; template['signingCertificate']=os.environ['DEVELOPER_ID_APPLICATION']
(p/'ExportOptions.plist').write_bytes(plistlib.dumps(template))
PY
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 7200 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$task_dir/certificate.p12" -k "$keychain_path" -P "$CERTIFICATE_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path" "${original_keychains[@]}"
security find-identity -v -p codesigning "$keychain_path" | python3 -c 'import os,sys; actual=sys.stdin.read(); expected=os.environ["DEVELOPER_ID_APPLICATION"]; sys.exit(0 if "\""+expected+"\"" in actual else "Developer ID Application certificate/private key not found in the temporary keychain.")'

version="${RELEASE_VERSION_TAG#v}"
xcodebuild -version
xcodebuild -resolvePackageDependencies -project MarkUp.xcodeproj -scheme MarkUp -clonedSourcePackagesDirPath .build/xcode-packages -onlyUsePackageVersionsFromResolvedFile
xcodebuild -project MarkUp.xcodeproj -scheme MarkUp -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$task_dir/MarkUp.xcarchive" -derivedDataPath "$task_dir/DerivedData" \
    -clonedSourcePackagesDirPath .build/xcode-packages -onlyUsePackageVersionsFromResolvedFile \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$RELEASE_BUILD_NUMBER" \
    MARKUP_UPDATE_FEED="$MARKUP_UPDATE_FEED" MARKUP_UPDATE_PUBLIC_KEY="$MARKUP_UPDATE_PUBLIC_KEY" archive
# Xcode's export flow re-signs Sparkle's nested helpers/XPC services for this team.
xcodebuild -exportArchive -archivePath "$task_dir/MarkUp.xcarchive" -exportOptionsPlist "$task_dir/ExportOptions.plist" -exportPath "$task_dir/export"
app_path="$task_dir/export/MarkUp.app"
python3 scripts/release-verify.py "$app_path" --team "$DEVELOPMENT_TEAM"

# Submit a ZIP, then staple the APP payload. ZIP archives cannot themselves be stapled.
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$task_dir/notarization.zip"
notary_auth=(--key "$task_dir/notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
submit_status=0
xcrun notarytool submit "$task_dir/notarization.zip" "${notary_auth[@]}" --wait --timeout 20m --output-format json > "$task_dir/notary-result.json" || submit_status=$?
submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$task_dir/notary-result.json")"
if [[ -z "$submission_id" ]]; then printf '%s\n' 'Notarization did not return a submission ID. Check account authentication and Apple service availability.' >&2; exit 1; fi
printf 'Notarization submission ID: %s\n' "$submission_id"
xcrun notarytool log "$submission_id" "${notary_auth[@]}" "$task_dir/notary-log.json"
python3 - "$task_dir/notary-result.json" "$task_dir/notary-log.json" "$submit_status" <<'PY'
import json,sys
result=json.load(open(sys.argv[1])); log=json.load(open(sys.argv[2]))
print('Notarization submission:',result.get('id'),'status:',result.get('status'))
if result.get('status')!='Accepted' or sys.argv[3]!='0':
    print('Apple issues:',json.dumps(log.get('issues',[])))
    raise SystemExit('Notarization not accepted; no distributable assets were created. Inspect the submission in notarytool history/log.')
PY
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
python3 scripts/release-verify.py "$app_path" --team "$DEVELOPMENT_TEAM"
spctl --assess --type execute --verbose=4 "$app_path"

final_output_dir="$repo_dir/artifacts/release"
if [[ -e "$final_output_dir" ]]; then printf '%s\n' 'artifacts/release already exists. Move the reviewed output aside before a new release run.' >&2; exit 1; fi
output_dir="$task_dir/release"
mkdir -p "$output_dir"
archive_name="MarkUp-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"
sparkle_bin="$repo_dir/.build/xcode-packages/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_bin/sign_update" && -x "$sparkle_bin/generate_appcast" ]] || { printf '%s\n' 'Pinned Sparkle command-line tools were not resolved.' >&2; exit 1; }
# All changes to the application/archive are finished before update signing.
"$sparkle_bin/sign_update" --ed-key-file "$task_dir/sparkle-private" -p "$output_dir/$archive_name" > "$task_dir/archive-signature"
signature="$(cat "$task_dir/archive-signature")"
swift scripts/release-verify-signature.swift "$output_dir/$archive_name" "$signature" "$MARKUP_UPDATE_PUBLIC_KEY"
"$sparkle_bin/sign_update" --verify --ed-key-file "$task_dir/sparkle-private" "$output_dir/$archive_name" "$signature"
"$sparkle_bin/generate_appcast" --ed-key-file "$task_dir/sparkle-private" --download-url-prefix "${MARKUP_DOWNLOAD_URL_PREFIX%/}/$RELEASE_VERSION_TAG/" --maximum-deltas 0 -o "$output_dir/appcast.xml" "$output_dir"
python3 - "$output_dir" "$archive_name" "$task_dir/archive-signature" "$task_dir/notary-result.json" <<'PY'
from pathlib import Path
import hashlib,json,os,sys,xml.etree.ElementTree as ET
p=Path(sys.argv[1]); archive=p/sys.argv[2]; signature=Path(sys.argv[3]).read_text().strip()
feed=p/'appcast.xml'; root=ET.parse(feed).getroot(); enclosure=root.find('./channel/item/enclosure')
assert enclosure is not None and enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')==signature, 'Generated feed signature differs from verified final ZIP signature'
assert enclosure.get('length')==str(archive.stat().st_size), 'Generated feed length differs from final archive'
assert enclosure.get('url')==os.environ['MARKUP_DOWNLOAD_URL_PREFIX'].rstrip('/')+'/'+os.environ['RELEASE_VERSION_TAG']+'/'+archive.name, 'Generated feed URL differs from intended final release URL'
for name in [archive.name,feed.name]:
    with (p/'SHA256SUMS').open('a') as out: out.write(hashlib.sha256((p/name).read_bytes()).hexdigest()+'  '+name+'\n')
evidence={'version':os.environ['RELEASE_VERSION_TAG'],'build':os.environ['RELEASE_BUILD_NUMBER'],
          'gitCommit':os.environ.get('GITHUB_SHA'),'notarization':json.loads(Path(sys.argv[4]).read_text()),
          'architecturesCompiled':['arm64','x86_64'],'architecturesExecutedDuringRelease':['host only; see CI host log'],
          'installRelaunchUpdateTest':'OWNER GATE: not executed by this workflow', 'published':False}
(p/'release-evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
PY
mkdir -p "$repo_dir/artifacts"
mv "$output_dir" "$final_output_dir"
printf '%s\n' 'Signed, notarized assets are ready in artifacts/release for owner review. Nothing has been published.'
