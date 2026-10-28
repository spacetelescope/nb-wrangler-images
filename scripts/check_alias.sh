#!/usr/bin/env bash
# Decide whether an image alias may be created.  Used by retag.yml.
#
#   source tag no longer matches the expected digest  -> refused
#   alias free                                         -> ok
#   alias already on the same image                    -> ok (a rerun is a no-op)
#   alias on a different image                         -> refused, unless allow_move is "true"
#   anything we cannot determine                       -> refused
#
# The last rule matters: a registry or auth error must never be read as
# "the alias is free", or a transient failure could overwrite a release.
#
# The expected digest, when given, is the digest the build reported.  Tags in a
# registry can be re-pointed by anyone who can write to the package, so the
# alias is only created for the exact image that was built and tested.
#
# usage: check_alias.sh <image-root> <input-tag> <output-tag> <allow-move> [expected-digest]
#   e.g. check_alias.sh ghcr.io/spacetelescope/nb-wrangler-images nbw_x_12 RomanNexus-2026.2.4 false sha256:...

# Stop on any error, on an unset variable, and on a failure inside a pipe.
set -euo pipefail

# Arguments. The allow-move flag and the expected digest are optional.
root=${1:?image root is required}
input_tag=${2:?input tag is required}
output_tag=${3:?output tag is required}
allow_move=${4:-false}
expected=${5:-}

# What a tag may look like, and what a digest looks like. Anything else is refused outright.
tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
digest_pattern='^sha256:[0-9a-f]{64}$'

# Validate both tags before they are used in any command.
for t in "$input_tag" "$output_tag"; do
    if ! [[ "$t" =~ $tag_pattern ]]; then
        echo "::error::'${t}' is not a valid image tag." >&2
        exit 1
    fi
done
if [[ -n "$expected" && ! "$expected" =~ $digest_pattern ]]; then
    echo "::error::Expected digest '${expected}' is not a sha256 digest." >&2
    exit 1
fi

# Sets DIGEST_OUT (stdout) and DIGEST_ERR (stderr) separately; a warning on
# stderr must not end up inside the digest.  Returns the command's status.
digest_of() {
    local errfile rc=0
    errfile=$(mktemp)
    DIGEST_OUT=$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>"$errfile") || rc=$?
    DIGEST_ERR=$(<"$errfile")
    rm -f "$errfile"
    return "$rc"
}

# True when the argument is a well-formed sha256 digest.
is_digest() { [[ "$1" =~ $digest_pattern ]]; }

# Step 1: the image we are about to alias must exist and report a real digest.
if ! digest_of "${root}:${input_tag}" || ! is_digest "$DIGEST_OUT"; then
    echo "::error::Source image ${root}:${input_tag} could not be inspected: ${DIGEST_ERR:-$DIGEST_OUT}" >&2
    exit 1
fi
source_digest=$DIGEST_OUT

# Step 2: if the build told us which digest it produced, the source tag must still point at it.
# If it has moved since the build, someone re-pointed it, and we refuse to alias an image nobody tested.
if [[ -n "$expected" && "$source_digest" != "$expected" ]]; then
    echo "::error::${input_tag} now points at ${source_digest}, not the ${expected} that was built. Refusing." >&2
    exit 1
fi

# Step 3: does the alias already exist? It then must point at the same image, or we may be asked to move it.
if digest_of "${root}:${output_tag}"; then
    if ! is_digest "$DIGEST_OUT"; then
        echo "::error::Unexpected output inspecting ${output_tag}: ${DIGEST_OUT}" >&2
        exit 1
    fi
    existing=$DIGEST_OUT
    if [[ "$existing" == "$source_digest" ]]; then
        echo "${output_tag} already points at ${input_tag} (${source_digest}); nothing to change."
    elif [[ "$allow_move" == "true" ]]; then
        echo "Moving ${output_tag} from ${existing} to ${source_digest}."
    else
        echo "::error::${output_tag} already exists on ${existing}, not ${source_digest}. Set allow_move to override." >&2
        exit 1
    fi
# The registry said the alias does not exist, so it is free.
elif grep -qiE 'not found|manifest unknown|404' <<<"$DIGEST_ERR"; then
    echo "${output_tag} is free."
# Any other failure (auth, network, a server error) means we do not know. Refuse rather than assume it is free.
else
    echo "::error::Could not determine whether ${output_tag} exists: ${DIGEST_ERR}" >&2
    exit 1
fi
