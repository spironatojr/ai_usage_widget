#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$PROJECT_ROOT/VERSION"
BUILD_FILE="$PROJECT_ROOT/BUILD_NUMBER"
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
MODE="${1:---apply}"

if [[ "$MODE" != "--apply" && "$MODE" != "--dry-run" ]]; then
    echo "Usage: $0 [--apply|--dry-run]" >&2
    exit 64
fi

cd "$PROJECT_ROOT"

[[ -f "$VERSION_FILE" ]] || { echo "Missing VERSION file" >&2; exit 1; }
[[ -f "$BUILD_FILE" ]] || { echo "Missing BUILD_NUMBER file" >&2; exit 1; }

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
CURRENT_BUILD="$(tr -d '[:space:]' < "$BUILD_FILE")"

[[ "$CURRENT_VERSION" =~ $SEMVER_PATTERN ]] || {
    echo "Invalid VERSION: $CURRENT_VERSION" >&2
    exit 1
}
[[ "$CURRENT_BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid BUILD_NUMBER: $CURRENT_BUILD" >&2
    exit 1
}

LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
    BASE_VERSION="${LAST_TAG#v}"
    RANGE="$LAST_TAG..HEAD"
else
    BASE_VERSION="$CURRENT_VERSION"
    RANGE="HEAD"
fi

[[ "$BASE_VERSION" =~ $SEMVER_PATTERN ]] || {
    echo "Latest version tag is not stable SemVer: $LAST_TAG" >&2
    exit 1
}

SUBJECTS="$(git log "$RANGE" --no-merges --format='%s')"
BODIES="$(git log "$RANGE" --no-merges --format='%b')"

if [[ -z "$SUBJECTS" ]]; then
    RELEASE_TYPE="none"
elif printf '%s\n%s\n' "$SUBJECTS" "$BODIES" | grep -Eq '^[a-z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:'; then
    RELEASE_TYPE="major"
elif printf '%s\n' "$SUBJECTS" | grep -Eq '^feat(\([^)]*\))?:'; then
    RELEASE_TYPE="minor"
elif printf '%s\n' "$SUBJECTS" | grep -Eq '^(fix|perf|refactor|revert)(\([^)]*\))?:'; then
    RELEASE_TYPE="patch"
else
    UNKNOWN_SUBJECTS="$(
        printf '%s\n' "$SUBJECTS" |
            grep -Ev '^(docs|test|ci|build|chore|style)(\([^)]*\))?:' || true
    )"
    if [[ -n "$UNKNOWN_SUBJECTS" ]]; then
        echo "Warning: non-conventional commits found; defaulting to patch:" >&2
        printf '%s\n' "$UNKNOWN_SUBJECTS" >&2
        RELEASE_TYPE="patch"
    else
        RELEASE_TYPE="none"
    fi
fi

write_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

if [[ "$RELEASE_TYPE" == "none" ]]; then
    echo "No release-worthy commits found after ${LAST_TAG:-the initial revision}."
    write_output release_required false
    write_output release_type none
    exit 0
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
case "$RELEASE_TYPE" in
    major) NEXT_VERSION="$((MAJOR + 1)).0.0" ;;
    minor) NEXT_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEXT_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac
NEXT_BUILD="$((CURRENT_BUILD + 1))"

if [[ "$MODE" == "--apply" ]]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Working tree must be clean before applying a semantic release" >&2
        exit 1
    fi
    printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
    printf '%s\n' "$NEXT_BUILD" > "$BUILD_FILE"
fi

echo "Release type: $RELEASE_TYPE"
echo "Version:      $BASE_VERSION -> $NEXT_VERSION"
echo "Build:        $CURRENT_BUILD -> $NEXT_BUILD"

write_output release_required true
write_output release_type "$RELEASE_TYPE"
write_output previous_version "$BASE_VERSION"
write_output version "$NEXT_VERSION"
write_output build "$NEXT_BUILD"
write_output tag "v$NEXT_VERSION"
