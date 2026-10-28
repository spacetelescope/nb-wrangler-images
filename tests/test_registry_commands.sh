#!/usr/bin/env bash
# Tests for the docker and registry commands the delivery pipeline depends on:
# scripts/image_digest.sh (digest after push) and scripts/check_alias.sh (alias
# immutability used by retag.yml).
#
#   stub  runs anywhere.  A fake `docker` returns canned answers, so this checks
#         the scripts' logic and error handling, not the real CLI.
#   real  needs a Docker daemon and a registry.  Builds two tiny images, pushes
#         them, and runs the same scripts against the real CLI.  This is what
#         proves the `--format` templates are valid.
#
# usage: tests/test_registry_commands.sh [stub|real|auto]
#   REGISTRY   registry host:port for real mode (default localhost:5000).  If it is
#              not reachable, a throwaway registry:2 container is started and removed.

# shellcheck disable=SC2015  # ok/bad never fail, so A && ok || bad is intentional
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-auto}
pass=0
fail=0

# Result helpers: count and print each check.
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# expect_exit <name> <expected-status> -- <command...>   (output kept in $out)
expect_exit() {
    local name=$1 want=$2
    shift 3
    out=$("$@" 2>&1)
    local got=$?
    if [[ "$got" -eq "$want" ]]; then ok "$name"; else bad "$name (exit $got, wanted $want): $out"; fi
}
expect_out() { # <name> <substring>
    if [[ "$out" == *"$2"* ]]; then ok "$1"; else bad "$1 (output lacked '$2'): $out"; fi
}

# Two distinct, well-formed digests used as fake image identities in stub mode.
d1="sha256:$(printf '1%.0s' {1..64})"
d2="sha256:$(printf '2%.0s' {1..64})"

# --------------------------------------------------------------------------- stub
# Stub mode: a fake docker lets us test the scripts' logic without a Docker daemon.
run_stub() {
    echo "== stub mode (fake docker; verifies script logic) =="
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/manifests" "$tmp/repodigests" "$tmp/errors"
    # The fake docker. It answers 'buildx imagetools inspect' from files in manifests/ and 'image inspect'
    # from repodigests/, and can simulate a down registry, a warning on stderr, or any error text.
    cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
key() { printf '%s' "$1" | tr '/:' '__'; }
case "$1 $2" in
  "buildx imagetools")
    ref=$4
    [[ -n "${STUB_REGISTRY_DOWN:-}" ]] && { echo "ERROR: failed to do request: Head https://$ref: dial tcp: connection refused" >&2; exit 1; }
    k=$(key "$ref")
    [[ -n "${STUB_WARN:-}" ]] && echo "WARNING: harmless buildx notice" >&2
    if [[ -f "$STUB_DIR/manifests/$k" ]]; then cat "$STUB_DIR/manifests/$k"; exit 0; fi
    if [[ -f "$STUB_DIR/errors/$k" ]]; then cat "$STUB_DIR/errors/$k" >&2; exit 1; fi
    echo "ERROR: $ref: not found" >&2; exit 1 ;;
  "image inspect")
    ref=${@: -1}; k=$(key "$ref")
    [[ -f "$STUB_DIR/repodigests/$k" ]] && { cat "$STUB_DIR/repodigests/$k"; exit 0; }
    echo "Error: No such image: $ref" >&2; exit 1 ;;
esac
echo "stub docker: unhandled: $*" >&2; exit 99
EOF
    chmod +x "$tmp/bin/docker"
    # Put the fake first on PATH so the scripts under test call it instead of the real docker.
    export STUB_DIR=$tmp PATH="$tmp/bin:$PATH"
    local root=reg.example:5000/nbw
    k() { printf '%s' "$1" | tr '/:' '__'; }
    unset STUB_REGISTRY_DOWN STUB_WARN

    echo "-- image_digest.sh"
    printf '%s@%s\n' "$root" "$d1" > "$tmp/repodigests/$(k "$root:t1")"
    expect_exit "returns the digest after push" 0 -- bash "$here/scripts/image_digest.sh" "$root:t1"
    [[ "$out" == "$d1" ]] && ok "digest value is exact" || bad "digest value: $out"
    printf 'other.example/x@%s\n%s@%s\n' "$d2" "$root" "$d1" > "$tmp/repodigests/$(k "$root:t2")"
    expect_exit "picks the digest for this repository, not the first line" 0 -- bash "$here/scripts/image_digest.sh" "$root:t2"
    [[ "$out" == "$d1" ]] && ok "multi-repository digest value" || bad "multi-repo digest: $out"
    printf 'other.example/x@%s\n' "$d2" > "$tmp/repodigests/$(k "$root:t3")"
    expect_exit "fails when only another repository has a digest" 1 -- bash "$here/scripts/image_digest.sh" "$root:t3"
    expect_out "  and says it may not be pushed" "pushed"
    : > "$tmp/repodigests/$(k "$root:t4")"
    expect_exit "fails when never pushed (no RepoDigests)" 1 -- bash "$here/scripts/image_digest.sh" "$root:t4"
    printf '%s@sha256:bad\n' "$root" > "$tmp/repodigests/$(k "$root:t5")"
    expect_exit "rejects a malformed digest" 1 -- bash "$here/scripts/image_digest.sh" "$root:t5"
    expect_exit "fails when the image does not exist" 1 -- bash "$here/scripts/image_digest.sh" "$root:nope"

    echo "-- check_alias.sh"
    printf '%s\n' "$d1" > "$tmp/manifests/$(k "$root:src")"
    expect_exit "free alias is allowed" 0 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.4 false
    expect_out "  reported as free" "is free"
    printf '%s\n' "$d1" > "$tmp/manifests/$(k "$root:RomanNexus-2026.2.4")"
    expect_exit "alias already on the same image is a no-op" 0 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.4 false
    expect_out "  reported as nothing to change" "nothing to change"
    printf '%s\n' "$d2" > "$tmp/manifests/$(k "$root:RomanNexus-2026.2.4")"
    expect_exit "alias on a different image is refused" 1 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.4 false
    expect_out "  names allow_move as the way out" "allow_move"
    expect_exit "different image allowed with allow_move=true" 0 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.4 true
    expect_out "  reported as a move" "Moving"
    expect_exit "allow_move='yes' does not count (only 'true')" 1 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.4 yes
    expect_exit "missing source image is refused" 1 -- bash "$here/scripts/check_alias.sh" "$root" no-such-src RomanNexus-2026.2.9 false
    expect_out "  explains the source problem" "could not be inspected"
    printf 'ERROR: unauthorized: authentication required\n' > "$tmp/errors/$(k "$root:locked")"
    expect_exit "auth error on the alias is NOT read as free" 1 -- bash "$here/scripts/check_alias.sh" "$root" src locked false
    expect_out "  fails closed with the reason" "Could not determine"
    printf 'ERROR: 500 Internal Server Error\n' > "$tmp/errors/$(k "$root:flaky")"
    expect_exit "server error on the alias is NOT read as free" 1 -- bash "$here/scripts/check_alias.sh" "$root" src flaky false
    export STUB_REGISTRY_DOWN=1
    expect_exit "registry unreachable is refused" 1 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.5 false
    unset STUB_REGISTRY_DOWN
    printf '%s\n' "$d1" > "$tmp/manifests/$(k "$root:RomanNexus-2026.2.6")"
    export STUB_WARN=1
    expect_exit "a stderr warning on success does not corrupt the digest" 0 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.6 false
    expect_out "  still sees the same digest" "nothing to change"
    unset STUB_WARN

    echo "-- check_alias.sh: tag validation"
    # shellcheck disable=SC2016  # '$(id)' is deliberately a literal test input
    for bad in 'a;rm -rf /' 'a b' '$(id)' '-leading-dash' '../x' 'a|b' "a'b"; do
        expect_exit "output tag '${bad}' is rejected" 1 -- bash "$here/scripts/check_alias.sh" "$root" src "$bad" false
    done
    expect_exit "input tag with shell metacharacters is rejected" 1 -- bash "$here/scripts/check_alias.sh" "$root" 'src;id' RomanNexus-2026.2.4 false
    expect_out "  and says why" "not a valid image tag"

    echo "-- check_alias.sh: expected digest"
    rm -f "$tmp/manifests/$(k "$root:RomanNexus-2026.2.9")"
    expect_exit "source matches the built digest" 0 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.9 false "$d1"
    expect_exit "source tag was re-pointed after the build" 1 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.9 false "$d2"
    expect_out "  says the tag moved" "now points at"
    expect_exit "a malformed expected digest is rejected" 1 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.9 false "sha256:short"
    expect_exit "digest mismatch is refused even with allow_move=true" 1 -- bash "$here/scripts/check_alias.sh" "$root" src RomanNexus-2026.2.9 true "$d2"
    rm -rf "$tmp"
}

# --------------------------------------------------------------------------- real
# Real mode: build two tiny images, push them to a registry, and run the scripts against the real docker CLI.
run_real() {
    echo "== real mode (docker + registry) =="
    if ! docker info >/dev/null 2>&1; then
        echo "  SKIP  no Docker daemon reachable"
        return 2
    fi
    local reg=${REGISTRY:-localhost:5000} started=""
    if ! curl -fsS "http://${reg}/v2/" >/dev/null 2>&1; then
        echo "  starting a throwaway registry:2 on ${reg}"
        docker run -d --rm --name rrn-test-registry -p "${reg##*:}:5000" registry:2 >/dev/null || { bad "could not start registry"; return 1; }
        started=1
        for _ in $(seq 1 30); do curl -fsS "http://${reg}/v2/" >/dev/null 2>&1 && break; sleep 1; done
    fi
    local root="${reg}/rrn-test" ctx
    ctx=$(mktemp -d)
    trap '[[ -n "$started" ]] && docker rm -f rrn-test-registry >/dev/null 2>&1; rm -rf "$ctx"' RETURN

    # Build a one-file image from scratch (so nothing needs downloading) and push it.
    build_push() { # <tag> <content>
        printf '%s' "$2" > "$ctx/payload"
        printf 'FROM scratch\nCOPY payload /payload\n' > "$ctx/Dockerfile"
        docker build -q -t "${root}:$1" "$ctx" >/dev/null && docker push -q "${root}:$1" >/dev/null
    }
    build_push src-a "image A $(date +%s%N)" && ok "built and pushed image A" || { bad "build/push A"; return 1; }
    build_push src-b "image B $(date +%s%N)" && ok "built and pushed image B" || { bad "build/push B"; return 1; }

    echo "-- image_digest.sh against a real push"
    expect_exit "digest is returned for a pushed image" 0 -- bash "$here/scripts/image_digest.sh" "${root}:src-a"
    local digest_a=$out
    [[ "$digest_a" =~ ^sha256:[0-9a-f]{64}$ ]] && ok "digest has the expected format" || bad "digest format: $digest_a"
    local from_registry
    from_registry=$(docker buildx imagetools inspect "${root}:src-a" --format '{{.Manifest.Digest}}')
    [[ "$digest_a" == "$from_registry" ]] && ok "digest matches what the registry reports" || bad "digest $digest_a vs registry $from_registry"
    docker build -q -t "${root}:never-pushed" "$ctx" >/dev/null
    expect_exit "a built-but-unpushed image has no digest" 1 -- bash "$here/scripts/image_digest.sh" "${root}:never-pushed"

    echo "-- check_alias.sh against a real registry"
    expect_exit "free alias is allowed" 0 -- bash "$here/scripts/check_alias.sh" "$root" src-a RomanNexus-2026.2.4 false
    docker tag "${root}:src-a" "${root}:RomanNexus-2026.2.4" && docker push -q "${root}:RomanNexus-2026.2.4" >/dev/null
    expect_exit "same image again is a no-op" 0 -- bash "$here/scripts/check_alias.sh" "$root" src-a RomanNexus-2026.2.4 false
    expect_exit "a different image is refused" 1 -- bash "$here/scripts/check_alias.sh" "$root" src-b RomanNexus-2026.2.4 false
    expect_exit "a different image moves with allow_move=true" 0 -- bash "$here/scripts/check_alias.sh" "$root" src-b RomanNexus-2026.2.4 true
    expect_exit "missing source is refused" 1 -- bash "$here/scripts/check_alias.sh" "$root" no-such-tag RomanNexus-2026.2.7 false
    expect_exit "an unreachable registry is refused, not read as free" 1 -- bash "$here/scripts/check_alias.sh" "localhost:1/rrn-test" src-a RomanNexus-2026.2.8 false

    echo "-- retag flow (what retag.yml does after the check)"
    docker pull -q "${root}:src-b" >/dev/null && docker tag "${root}:src-b" "${root}:RomanNexus-2026.2.4" && docker push -q "${root}:RomanNexus-2026.2.4" >/dev/null && ok "moved alias pushed" || bad "retag push"
    local alias_digest src_b_digest
    alias_digest=$(docker buildx imagetools inspect "${root}:RomanNexus-2026.2.4" --format '{{.Manifest.Digest}}')
    src_b_digest=$(docker buildx imagetools inspect "${root}:src-b" --format '{{.Manifest.Digest}}')
    [[ "$alias_digest" == "$src_b_digest" ]] && ok "alias and source now share a digest" || bad "alias $alias_digest vs src $src_b_digest"

    echo "-- retag by digest (what retag.yml does when input_digest is given)"
    local digest_a_now
    digest_a_now=$(docker buildx imagetools inspect "${root}:src-a" --format '{{.Manifest.Digest}}')
    expect_exit "check passes with the matching expected digest" 0 -- bash "$here/scripts/check_alias.sh" "$root" src-a RomanNexus-2026.2.11 false "$digest_a_now"
    expect_exit "alias is created from the digest, without pulling" 0 -- docker buildx imagetools create --tag "${root}:RomanNexus-2026.2.11" "${root}@${digest_a_now}"
    local by_digest
    by_digest=$(docker buildx imagetools inspect "${root}:RomanNexus-2026.2.11" --format '{{.Manifest.Digest}}')
    [[ "$by_digest" == "$digest_a_now" ]] && ok "alias made by digest resolves to that digest" || bad "by-digest alias $by_digest vs $digest_a_now"
    expect_exit "check refuses once the source tag points elsewhere" 1 -- bash "$here/scripts/check_alias.sh" "$root" src-b RomanNexus-2026.2.12 false "$digest_a_now"
    return 0
}

# --------------------------------------------------------------------------- main
# Pick the mode. 'auto' runs stub, then real (real is skipped without a Docker daemon).
real_status=0
case "$mode" in
    stub) run_stub ;;
    real) run_real; real_status=$? ;;
    auto) run_stub; run_real; real_status=$? ;;
    *) echo "usage: $0 [stub|real|auto]" >&2; exit 64 ;;
esac

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ "$real_status" -eq 2 && "$mode" == "real" ]]; then
    echo "real mode did not run (no Docker daemon)"
    exit 2
fi
exit 0
