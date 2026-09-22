#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"
BUILD_FILE="$PROJECT_ROOT/BUILD_NUMBER"
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

usage() {
    echo "Usage: $0 major|minor|patch|MAJOR.MINOR.PATCH" >&2
    exit 64
}

[[ $# -eq 1 ]] || usage
[[ -f "$VERSION_FILE" ]] || { echo "Missing VERSION file" >&2; exit 1; }
[[ -f "$BUILD_FILE" ]] || { echo "Missing BUILD_NUMBER file" >&2; exit 1; }

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
CURRENT_BUILD="$(tr -d '[:space:]' < "$BUILD_FILE")"

[[ "$CURRENT_VERSION" =~ $SEMVER_PATTERN ]] || {
    echo "Invalid current version: $CURRENT_VERSION" >&2
    exit 1
}
[[ "$CURRENT_BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid current build number: $CURRENT_BUILD" >&2
    exit 1
}

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$1" in
    major)
        NEXT_VERSION="$((MAJOR + 1)).0.0"
        ;;
    minor)
        NEXT_VERSION="$MAJOR.$((MINOR + 1)).0"
        ;;
    patch)
        NEXT_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
        ;;
    *)
        [[ "$1" =~ $SEMVER_PATTERN ]] || usage
        NEXT_VERSION="$1"
        ;;
esac

IFS='.' read -r NEXT_MAJOR NEXT_MINOR NEXT_PATCH <<< "$NEXT_VERSION"
if (( NEXT_MAJOR < MAJOR )) ||
    (( NEXT_MAJOR == MAJOR && NEXT_MINOR < MINOR )) ||
    (( NEXT_MAJOR == MAJOR && NEXT_MINOR == MINOR && NEXT_PATCH <= PATCH )); then
    echo "New version must be greater than $CURRENT_VERSION" >&2
    exit 1
fi

NEXT_BUILD="$((CURRENT_BUILD + 1))"

printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
printf '%s\n' "$NEXT_BUILD" > "$BUILD_FILE"

echo "Version: $CURRENT_VERSION -> $NEXT_VERSION"
echo "Build:   $CURRENT_BUILD -> $NEXT_BUILD"
