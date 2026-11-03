#!/usr/bin/env bash
# Print the registry digest (sha256:...) of an image that has already been pushed.
#
# A local image only has a RepoDigest for a repository after a push to it, and may
# carry several (one per repository it was pushed to), so the one matching the
# image's own repository is selected rather than blindly taking the first.
#
# usage: image_digest.sh <image-reference>   e.g. ghcr.io/spacetelescope/nb-wrangler-images:nbw_x_12

set -euo pipefail

image=${1:?image reference is required}

# Strip the tag, but only if the last path component has one (a registry port
# such as localhost:5000/... is not a tag).
last=${image##*/}
if [[ "$last" == *:* ]]; then
    repo=${image%:*}
else
    repo=$image
fi

# Every digest this local image has, one per repository it was pushed to.
repo_digests=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image")
# Pick the digest for this image's own repository, not just the first line.
digest=$(printf '%s\n' "$repo_digests" | grep -F -- "${repo}@" | head -n1 | cut -d@ -f2 || true)

# No digest, or a malformed one, almost always means the image was never pushed.
if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "No registry digest for ${image} (RepoDigests: ${repo_digests:-none}). Has it been pushed?" >&2
    exit 1
fi
printf '%s\n' "$digest"
