#!/usr/bin/env bash
# Runs the Firestore security-rules tests against the LOCAL emulator only.
# The project id starts with "demo-", so nothing can reach a real project.
# Ports 8012 / hub 4412 / logging 4512 avoid clashing with a dev emulator.
# Needs a JDK 17 (firebase-tools 13.x; the installed 15.x wants JDK 21).
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm ci --no-audit --no-fund
# The emulator config may not reference files outside this directory; the
# test itself loads ../../firestore.rules directly.
cp ../../firestore.rules .firestore.rules.copy
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
npx -y firebase-tools@13.35.1 emulators:exec --only firestore \
  --project demo-feltnotes --config firebase.json \
  "node rules.test.js"
