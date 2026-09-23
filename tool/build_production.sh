#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env.production ]]; then
  echo '.env.production 파일이 없습니다.' >&2
  exit 1
fi

cleanup() {
  rm -f .env
}
trap cleanup EXIT

cp .env.production .env
flutter build apk --release
