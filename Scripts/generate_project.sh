#!/bin/zsh
set -eu
cd "${0:A:h:h}"
if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 'Install XcodeGen (brew install xcodegen), or open the included AirGuitar.xcodeproj.'
  exit 1
fi
xcodegen generate --spec project.yml
