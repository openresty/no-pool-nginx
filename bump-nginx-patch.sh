#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 <old-version> <new-version>" >&2
    echo "Example: $0 1.31.3 1.31.4" >&2
}

if (( $# != 2 )); then
    usage
    exit 2
fi

old_version=$1
new_version=$2

version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! $old_version =~ $version_pattern || ! $new_version =~ $version_pattern ]]; then
    echo "Error: versions must use the <major>.<minor>.<patch> format." >&2
    exit 2
fi

if [[ $old_version == "$new_version" ]]; then
    echo "Error: old and new versions must be different." >&2
    exit 2
fi

nginx_version_number() {
    local version=$1
    local major minor patch

    IFS=. read -r major minor patch <<< "$version"
    printf '%d' "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
}

old_number=$(nginx_version_number "$old_version")
new_number=$(nginx_version_number "$new_version")

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

nginx_dir="$script_dir/../nginx"
release_ref="release-${new_version}"

if ! git -C "$nginx_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: $nginx_dir is not a Git work tree." >&2
    exit 1
fi

if [[ -n $(git -C "$nginx_dir" status --porcelain --untracked-files=no) ]]; then
    echo "Error: $nginx_dir has tracked changes; refusing to overwrite them during validation." >&2
    exit 1
fi

if ! git -C "$nginx_dir" rev-parse --verify --quiet "${release_ref}^{commit}" >/dev/null; then
    echo "Error: nginx release does not exist: $release_ref" >&2
    exit 1
fi

if ! git -C "$nginx_dir" rev-parse --verify --quiet "master^{commit}" >/dev/null; then
    echo "Error: nginx master branch does not exist." >&2
    exit 1
fi

old_patch="nginx-${old_version}-no_pool.patch"
new_patch="nginx-${new_version}-no_pool.patch"

if [[ ! -f $old_patch ]]; then
    echo "Error: source patch does not exist: $old_patch" >&2
    exit 1
fi

if [[ -e $new_patch ]]; then
    echo "Error: target patch already exists: $new_patch" >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: $script_dir is not inside a Git work tree." >&2
    exit 1
fi

if ! grep -Fq "$old_version" "$old_patch"; then
    echo "Error: $old_patch does not contain version $old_version." >&2
    exit 1
fi

if ! grep -Fq "$old_number" "$old_patch"; then
    echo "Error: $old_patch does not contain nginx version number $old_number." >&2
    exit 1
fi

cp -- "$old_patch" "$new_patch"

old_version_re=${old_version//./\\.}
sed -i \
    -e "s/${old_version_re}/${new_version}/g" \
    -e "s/${old_number}/${new_number}/g" \
    "$new_patch"

cleanup_needed=0

cleanup_nginx() {
    local cleanup_status=0

    echo "Cleaning nginx work tree and returning to master"

    if ! git -C "$nginx_dir" checkout .; then
        echo "Error: failed to clean tracked changes in $nginx_dir." >&2
        cleanup_status=1
    fi

    if ! git -C "$nginx_dir" checkout master; then
        echo "Error: failed to return $nginx_dir to master." >&2
        cleanup_status=1
    fi

    return "$cleanup_status"
}

cleanup_on_exit() {
    local status=$?

    if (( cleanup_needed )); then
        cleanup_nginx || status=1
    fi

    exit "$status"
}

trap cleanup_on_exit EXIT
cleanup_needed=1

echo "Checking out $release_ref in $nginx_dir"
git -C "$nginx_dir" checkout "$release_ref"

patch_status=0
echo "Validating $new_patch against $release_ref"
(cd "$nginx_dir" && patch -p1 --batch < "$script_dir/$new_patch") || patch_status=$?

cleanup_status=0
cleanup_nginx || cleanup_status=$?
cleanup_needed=0
trap - EXIT

if (( patch_status != 0 )); then
    echo "Error: patch validation failed for $new_patch against $release_ref (patch exit status: $patch_status)." >&2
    exit "$patch_status"
fi

if (( cleanup_status != 0 )); then
    exit "$cleanup_status"
fi

echo "Patch validation succeeded for $new_patch against $release_ref"

git add -- "$new_patch"
git commit --only -m "feature: add no-pool patch for nginx ${new_version}" -- "$new_patch"

echo "Created, validated, and committed $new_patch"
