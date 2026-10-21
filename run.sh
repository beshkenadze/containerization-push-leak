#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ -n "${CONTAINERIZATION_PATH:-}" ]; then
    scratch=".build-local"
else
    export CONTAINERIZATION_VERSION="${CONTAINERIZATION_VERSION:-0.52.1}"
    scratch=".build-$CONTAINERIZATION_VERSION"
fi

mkdir -p "$scratch"
if [ -f "$scratch/Package.resolved" ]; then cp "$scratch/Package.resolved" Package.resolved; fi
swift build -c release --scratch-path "$scratch" --product push-leak-repro 1>&2
if [ -f Package.resolved ]; then cp Package.resolved "$scratch/Package.resolved"; fi

exec "$scratch/release/push-leak-repro" "$@"
