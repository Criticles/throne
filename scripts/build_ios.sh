# Сборка неподписанного .ipa локально на macOS (то же, что делает CI).
# На Windows этот скрипт бесполезен — используйте GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$ROOT/.core/sing-box"
SINGBOX_REPO=$(sed -n 's/^SINGBOX_REPO=//p' "$ROOT/core/singbox-ref.txt")
SINGBOX_REF=$(sed -n 's/^SINGBOX_REF=//p' "$ROOT/core/singbox-ref.txt")
IOS_TAGS=$(sed -n 's/^IOS_TAGS=//p' "$ROOT/core/singbox-ref.txt")
IOS_MIN=$(sed -n 's/^IOS_MIN_VERSION=//p' "$ROOT/core/singbox-ref.txt")

echo "== ядро: $SINGBOX_REPO@$SINGBOX_REF"
mkdir -p "$ROOT/.core"
if [ ! -d "$CORE_DIR/.git" ]; then
  git init -q "$CORE_DIR"
  git -C "$CORE_DIR" remote add origin "$SINGBOX_REPO"
fi
git -C "$CORE_DIR" fetch -q --depth 1 origin "$SINGBOX_REF"
git -C "$CORE_DIR" checkout -q --detach FETCH_HEAD

echo "== gomobile"
export PATH="$(go env GOPATH)/bin:$PATH"
command -v gomobile >/dev/null || {
  go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
  go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
}
gomobile init

echo "== bind"
mkdir -p "$ROOT/ios/Frameworks"
cd "$CORE_DIR"
gomobile bind -v \
  -target ios,iossimulator \
  -o "$ROOT/ios/Frameworks/Libbox.xcframework" \
  -libname=Libbox \
  -iosversion "$IOS_MIN" \
  -tags "$IOS_TAGS" \
  -ldflags "-s -w -checklinkname=0" \
  ./experimental/libbox

echo "== xcodegen"
cd "$ROOT/ios"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

echo "== xcodebuild"
mkdir -p build
xcodebuild \
  -project Throne.xcodeproj \
  -scheme Throne \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | tee build/xcodebuild.log

echo "== .ipa"
rm -rf build/Payload build/Throne-unsigned.ipa
mkdir -p build/Payload
cp -R build/dd/Build/Products/Release-iphoneos/Throne.app build/Payload/
(cd build && zip -qry Throne-unsigned.ipa Payload)
echo "готово: $ROOT/ios/build/Throne-unsigned.ipa"
