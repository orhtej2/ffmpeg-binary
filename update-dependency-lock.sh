#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/" && pwd)"
LOCK_FILE="$ROOT_DIR/dependencies.lock"

if [[ ! -f "$LOCK_FILE" ]]; then
  echo "Lock file not found: $LOCK_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$LOCK_FILE"

latest_tag_from_remote() {
  local repo_url="$1"
  local tag_pattern="$2"

  local tags
  tags=$(git ls-remote --tags --refs "$repo_url" \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | grep -Ei "$tag_pattern" \
    | grep -Eiv 'alpha|beta|rc|pre|preview' || true)

  if [[ -z "$tags" ]]; then
    return 1
  fi

  printf '%s\n' "$tags" | sort -V | tail -n 1
}

update_var_if_newer() {
  local var_name="$1"
  local repo_var_name="$2"
  local tag_pattern="$3"

  local current_tag="${!var_name}"
  local repo_url="${!repo_var_name}"

  local latest_tag
  if ! latest_tag=$(latest_tag_from_remote "$repo_url" "$tag_pattern"); then
    echo "Could not resolve latest tag for $repo_url"
    return 0
  fi

  if [[ "$latest_tag" != "$current_tag" ]]; then
    printf -v "$var_name" '%s' "$latest_tag"
    echo "Updated $var_name: $current_tag -> $latest_tag"
    return 0
  fi

  echo "No change for $var_name ($current_tag)"
}

update_ref_if_newer() {
  local var_name="$1"
  local repo_var_name="$2"
  local branch="$3"

  local current_ref="${!var_name}"
  local repo_url="${!repo_var_name}"

  local latest_ref
  latest_ref=$(git ls-remote "$repo_url" "refs/heads/$branch" | awk '{print $1}')

  if [[ -z "$latest_ref" ]]; then
    echo "Could not resolve latest commit for $repo_url"
    return 0
  fi

  if [[ "$latest_ref" != "$current_ref" ]]; then
    printf -v "$var_name" '%s' "$latest_ref"
    echo "Updated $var_name: $current_ref -> $latest_ref"
    return 0
  fi

  echo "No change for $var_name ($current_ref)"
}

update_var_if_newer "ZLIB_TAG" "ZLIB_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBOGG_TAG" "LIBOGG_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBVORBIS_TAG" "LIBVORBIS_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "OPUS_TAG" "OPUS_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LAME_TAG" "LAME_REPO" '^RELEASE__[0-9]+_[0-9]+$'
update_var_if_newer "LIBVPX_TAG" "LIBVPX_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "LIBAOM_TAG" "LIBAOM_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "DAV1D_TAG" "DAV1D_REPO" '^[0-9]+(\.[0-9]+){1,3}$'
update_ref_if_newer "X264_REF" "X264_REPO" "master"
update_var_if_newer "X265_TAG" "X265_REPO" '^[0-9]+(\.[0-9]+){0,3}$'
update_var_if_newer "EXPAT_TAG" "EXPAT_REPO" '^R_[0-9]+_[0-9]+_[0-9]+$'
update_var_if_newer "FREETYPE_TAG" "FREETYPE_REPO" '^VER-[0-9]+(-[0-9]+){2,3}$'
update_var_if_newer "HARFBUZZ_TAG" "HARFBUZZ_REPO" '^v?[0-9]+(\.[0-9]+){1,3}$'
update_var_if_newer "FRIBIDI_TAG" "FRIBIDI_REPO" '^v?[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "FONTCONFIG_TAG" "FONTCONFIG_REPO" '^[0-9]+(\.[0-9]+){2,3}$'
update_var_if_newer "LIBASS_TAG" "LIBASS_REPO" '^[0-9]+(\.[0-9]+){2,3}$'

cat > "$LOCK_FILE" <<EOF
# Pinned dependency sources and tags for build.sh
# Update with: ./update-dependency-lock.sh

ZLIB_REPO="$ZLIB_REPO"
ZLIB_TAG="$ZLIB_TAG"

LIBOGG_REPO="$LIBOGG_REPO"
LIBOGG_TAG="$LIBOGG_TAG"

LIBVORBIS_REPO="$LIBVORBIS_REPO"
LIBVORBIS_TAG="$LIBVORBIS_TAG"

OPUS_REPO="$OPUS_REPO"
OPUS_TAG="$OPUS_TAG"

LAME_REPO="$LAME_REPO"
LAME_TAG="$LAME_TAG"

LIBVPX_REPO="$LIBVPX_REPO"
LIBVPX_TAG="$LIBVPX_TAG"

LIBAOM_REPO="$LIBAOM_REPO"
LIBAOM_TAG="$LIBAOM_TAG"

DAV1D_REPO="$DAV1D_REPO"
DAV1D_TAG="$DAV1D_TAG"

X264_REPO="$X264_REPO"
X264_REF="$X264_REF"

X265_REPO="$X265_REPO"
X265_TAG="$X265_TAG"

EXPAT_REPO="$EXPAT_REPO"
EXPAT_TAG="$EXPAT_TAG"

FREETYPE_REPO="$FREETYPE_REPO"
FREETYPE_TAG="$FREETYPE_TAG"

HARFBUZZ_REPO="$HARFBUZZ_REPO"
HARFBUZZ_TAG="$HARFBUZZ_TAG"

FRIBIDI_REPO="$FRIBIDI_REPO"
FRIBIDI_TAG="$FRIBIDI_TAG"

FONTCONFIG_REPO="$FONTCONFIG_REPO"
FONTCONFIG_TAG="$FONTCONFIG_TAG"

LIBASS_REPO="$LIBASS_REPO"
LIBASS_TAG="$LIBASS_TAG"
EOF

echo "Wrote updated lock file: $LOCK_FILE"
