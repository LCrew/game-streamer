#!/usr/bin/env bash
# Build and push ghcr.io/5stackgg/game-streamer from the local checkout.
# Useful while on a feature branch, where CI does not push images.
#
# Usage:
#   ./push-latest.sh           # -> :latest  (+ :<sha>)
#   ./push-latest.sh dev       # -> :dev     (+ :<sha>)  test image
#   ./push-latest.sh dev rc    # -> :dev :rc (+ :<sha>)
#
# Publishing a channel other than latest: read the warm cache, write your own.
#   CACHE_TO_REF=ghcr.io/5stackgg/game-streamer:buildcache-beta ./push-latest.sh beta
#
# Pushing from a fork:
#   IMAGE=ghcr.io/<you>/game-streamer ./push-latest.sh dev
#
# The :<sha> tag is always added so a pushed image is traceable back to a
# commit even when the named tag is mutable.
set -euo pipefail

# Overridable so a fork can push to its own registry. The script already exists
# for the "on a feature branch, CI does not push" case, and a fork cannot push
# to 5stackgg at all -- so the default is the upstream name, and IMAGE is how
# you point it at yours:
#   IMAGE=ghcr.io/<you>/game-streamer ./push-latest.sh dev
IMAGE="${IMAGE:-ghcr.io/5stackgg/game-streamer}"
# Split from/to so a non-latest build can READ the warm main cache without
# WRITING over it — CI's :latest builds restore from :buildcache, and pushing
# another channel's layers there would poison them.
# A fork's first build has no cache of its own to restore from. buildx treats a
# missing cache ref as a warning, not an error, so this is safe to leave
# pointing at a tag that does not exist yet -- and CACHE_FROM_REF can be aimed
# at upstream's warm cache to speed up that first build.
CACHE_FROM_REF="${CACHE_FROM_REF:-${IMAGE}:buildcache}"
CACHE_TO_REF="${CACHE_TO_REF:-${IMAGE}:buildcache}"
SHA="$(git rev-parse HEAD)"

# Tags: positional args, or $TAGS, defaulting to "latest".
if [ "$#" -gt 0 ]; then
  TAGS=( "$@" )
else
  # shellcheck disable=SC2206  # intentional word-split of $TAGS
  TAGS=( ${TAGS:-latest} )
fi

cd "$(dirname "$0")"

tag_args=()
for t in "${TAGS[@]}"; do
  tag_args+=( --tag "${IMAGE}:${t}" )
done
tag_args+=( --tag "${IMAGE}:${SHA}" )

echo "building + pushing ${IMAGE} with tags: ${TAGS[*]} ${SHA}"
docker buildx build \
  --platform linux/amd64 \
  --push \
  "${tag_args[@]}" \
  --cache-from "type=registry,ref=${CACHE_FROM_REF}" \
  --cache-to "type=registry,ref=${CACHE_TO_REF},mode=max" \
  .
