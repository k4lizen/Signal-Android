#!/usr/bin/env bash

set -euxo pipefail

# build the reproducible builds docker
docker build -t signal-build-env reproducible-builds

KEY_DIR="$PWD/meow-creds"
mkdir -p $KEY_DIR

export SIGNAL_SIGNING_PASSWORD='another-day-another-time'

# Run only once to generate the key
# docker run --rm -it \
#   --user "$(id -u):$(id -g)" \
#   -e SIGNAL_SIGNING_PASSWORD \
#   -v "$KEY_DIR":/keys \
#   signal-build-env \
#   keytool -genkeypair -v \
#     -keystore /keys/signal-release.p12 \
#     -storetype PKCS12 \
#     -alias signal-self \
#     -keyalg RSA \
#     -keysize 4096 \
#     -sigalg SHA256withRSA \
#     -validity 36500 \
#     -dname "CN=beep boop incorporated" \
#     -storepass:env SIGNAL_SIGNING_PASSWORD \
#     -keypass:env SIGNAL_SIGNING_PASSWORD

# build app
docker run --rm \
    -v "$PWD":/project \
    -w /project \
    --user "$(id -u):$(id -g)" \
    signal-build-env \
    ./gradlew clean assembleGithubProdRelease \
      -Pandroid.buildOnlyTargetAbi=true \
      -Pandroid.injected.build.abi=arm64-v8a

# find apk
UNSIGNED_APK="$(find \
  "$PWD/app/build/intermediates/apk/githubProd/release" \
  -maxdepth 1 \
  -type f \
  -iname '*arm64-v8a*.apk' \
  -print -quit)"

test -n "$UNSIGNED_APK"

BUILD_ID="$(git describe --tags --always --dirty | tr '/ ' '__')"
OUT_DIR="$PWD/meow-build"
ALIGNED_NAME="Signal-${BUILD_ID}-arm64-v8a-aligned-unsigned.apk"
SIGNED_NAME="Signal-${BUILD_ID}-arm64-v8a.apk"

mkdir -p "$OUT_DIR"

# align the build
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$UNSIGNED_APK":/input.apk:ro \
  -v "$OUT_DIR":/out \
  signal-build-env \
  /usr/local/android-sdk-linux/build-tools/36.0.0/zipalign \
    -P 16 -f 4 \
    /input.apk "/out/$ALIGNED_NAME"

# sign the build
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e SIGNAL_SIGNING_PASSWORD \
  -v "$KEY_DIR":/keys:ro \
  -v "$OUT_DIR":/out \
  signal-build-env \
  /usr/local/android-sdk-linux/build-tools/36.0.0/apksigner \
    sign \
    --ks /keys/signal-release.p12 \
    --ks-key-alias signal-self \
    --ks-pass env:SIGNAL_SIGNING_PASSWORD \
    --key-pass env:SIGNAL_SIGNING_PASSWORD \
    --v4-signing-enabled false \
    --out "/out/$SIGNED_NAME" \
    "/out/$ALIGNED_NAME"

# verify signature
docker run --rm \
  -v "$OUT_DIR":/out:ro \
  signal-build-env \
  /usr/local/android-sdk-linux/build-tools/36.0.0/apksigner \
    verify --verbose --print-certs "/out/$SIGNED_NAME"

# verify alignment
docker run --rm \
  -v "$OUT_DIR":/out:ro \
  signal-build-env \
  /usr/local/android-sdk-linux/build-tools/36.0.0/zipalign \
    -c -P 16 -v 4 "/out/$SIGNED_NAME"

# verify ABI
docker run --rm \
  -v "$OUT_DIR":/out:ro \
  signal-build-env \
  /usr/local/android-sdk-linux/build-tools/36.0.0/aapt \
    dump badging "/out/$SIGNED_NAME" |
  grep '^native-code:'

set +x
printf 'Built and signed APK @ %s\n' "$OUT_DIR/$SIGNED_NAME"
printf "Install with 'adb install -r -t %s'" "$OUT_DIR/$SIGNED_NAME"
