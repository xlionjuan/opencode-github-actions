#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-opencode}"
REPO="${OPENCODE_REPO:-anomalyco/opencode}"
VERSION="${OPENCODE_VERSION:-}"
INSTALL_DIR="${OPENCODE_INSTALL_DIR:-$HOME/.opencode/bin}"
CACHE_DIR="${OPENCODE_CACHE_DIR:-$HOME/.cache/opencode}"

usage() {
    cat <<'EOF'
Usage: opencode-release.sh <metadata|install>
EOF
}

log_info() {
    printf 'opencode-release: %s\n' "$*" >&2
}

log_warn() {
    printf 'opencode-release: warning: %s\n' "$*" >&2
}

log_error() {
    printf 'opencode-release: error: %s\n' "$*" >&2
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "required command not found: $cmd"
        exit 1
    fi
}

detect_target() {
    local raw_os os arch combo archive_ext is_musl needs_baseline rosetta_flag

    raw_os=$(uname -s)
    os=$(echo "$raw_os" | tr '[:upper:]' '[:lower:]')
    case "$raw_os" in
        Darwin*) os="darwin" ;;
        Linux*) os="linux" ;;
    esac

    arch=$(uname -m)
    if [[ "$arch" == "aarch64" ]]; then
        arch="arm64"
    fi
    if [[ "$arch" == "x86_64" ]]; then
        arch="x64"
    fi

    if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
        rosetta_flag=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
        if [ "$rosetta_flag" = "1" ]; then
            arch="arm64"
        fi
    fi

    combo="$os-$arch"
    case "$combo" in
        linux-x64|linux-arm64|darwin-x64|darwin-arm64)
            ;;
        *)
            log_error "unsupported OS/arch: $os/$arch"
            exit 1
            ;;
    esac

    archive_ext=".zip"
    if [ "$os" = "linux" ]; then
        archive_ext=".tar.gz"
    fi

    is_musl=false
    if [ "$os" = "linux" ]; then
        if [ -f /etc/alpine-release ]; then
            is_musl=true
        fi

        if command -v ldd >/dev/null 2>&1; then
            if ldd --version 2>&1 | grep -qi musl; then
                is_musl=true
            fi
        fi
    fi

    needs_baseline=false
    if [ "$arch" = "x64" ]; then
        if [ "$os" = "linux" ]; then
            if ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
                needs_baseline=true
            fi
        fi

        if [ "$os" = "darwin" ]; then
            local avx2
            avx2=$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)
            if [ "$avx2" != "1" ]; then
                needs_baseline=true
            fi
        fi
    fi

    target="$os-$arch"
    if [ "$needs_baseline" = "true" ]; then
        target="$target-baseline"
    fi
    if [ "$is_musl" = "true" ]; then
        target="$target-musl"
    fi

    filename="$APP-$target$archive_ext"

    printf '%s %s %s\n' "$target" "$archive_ext" "$filename"
}

sha256_of_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        log_error "neither sha256sum nor shasum is available"
        exit 1
    fi
}

fetch_asset_metadata() {
    local target archive_ext filename asset_digest asset_download_url
    read -r target archive_ext filename < <(detect_target)

    log_info "resolving $REPO release $VERSION for target $target"

    require_cmd gh

    asset_digest=$(ASSET_NAME="$filename" gh api "repos/$REPO/releases/tags/$VERSION" --jq '.assets[] | select(.name == env.ASSET_NAME) | .digest')
    asset_download_url=$(ASSET_NAME="$filename" gh api "repos/$REPO/releases/tags/$VERSION" --jq '.assets[] | select(.name == env.ASSET_NAME) | .browser_download_url')

    if [[ -z "$asset_digest" || -z "$asset_download_url" ]]; then
        log_error "release asset not found: $filename"
        exit 1
    fi

    if [[ "$asset_digest" != sha256:* ]]; then
        log_error "unexpected digest format for $filename: $asset_digest"
        exit 1
    fi

    log_info "resolved asset $filename (${asset_digest#sha256:})"

    printf 'version=%s\n' "$VERSION"
    printf 'target=%s\n' "$target"
    printf 'archive_ext=%s\n' "$archive_ext"
    printf 'filename=%s\n' "$filename"
    printf 'asset_digest=%s\n' "$asset_digest"
    printf 'asset_digest_hex=%s\n' "${asset_digest#sha256:}"
    printf 'asset_download_url=%s\n' "$asset_download_url"
    printf 'install_dir=%s\n' "$INSTALL_DIR"
    printf 'cache_dir=%s\n' "$CACHE_DIR/$VERSION/$target"
}

verify_cached_archive() {
    local archive_path="$1"
    local expected_digest_hex="$2"
    local actual_digest_hex

    actual_digest_hex="$(sha256_of_file "$archive_path")"
    if [[ "$actual_digest_hex" != "$expected_digest_hex" ]]; then
        log_warn "sha256 mismatch for $(basename "$archive_path")"
        log_warn "expected: $expected_digest_hex"
        log_warn "actual:   $actual_digest_hex"
        return 1
    fi
}

download_archive() {
    local dest_dir="$1"
    local filename="$2"
    local download_url="$3"

    mkdir -p "$dest_dir"

    log_info "downloading $download_url"
    if ! curl -fsSL -o "$dest_dir/$filename" "$download_url"; then
        log_error "failed to download $filename from $download_url"
        exit 1
    fi
}

install_from_archive() {
    local archive_path="$1"
    local install_dir="$2"
    local tmp_extract="$3"

    mkdir -p "$install_dir" "$tmp_extract"

    log_info "extracting $(basename "$archive_path")"
    case "$archive_path" in
        *.tar.gz)
            tar -xzf "$archive_path" -C "$tmp_extract"
            ;;
        *.zip)
            unzip -q "$archive_path" -d "$tmp_extract"
            ;;
        *)
            log_error "unsupported archive format for $archive_path"
            exit 1
            ;;
    esac

    if [ ! -f "$tmp_extract/opencode" ]; then
        log_error "opencode binary not found in $archive_path"
        exit 1
    fi

    mv "$tmp_extract/opencode" "$install_dir/opencode"
    chmod 755 "$install_dir/opencode"
    log_info "installed opencode to $install_dir/opencode"
}

install_release() {
    local filename asset_digest_hex asset_download_url cache_dir archive_path download_dir downloaded_archive
    local runner_temp tmp_extract_dir

    if [ -n "${OPENCODE_FILENAME:-}" ] && [ -n "${OPENCODE_DIGEST_HEX:-}" ] && [ -n "${OPENCODE_CACHE_DIR:-}" ]; then
        filename="$OPENCODE_FILENAME"
        asset_digest_hex="$OPENCODE_DIGEST_HEX"
        cache_dir="$OPENCODE_CACHE_DIR"
        asset_download_url="${OPENCODE_DOWNLOAD_URL:-https://github.com/$REPO/releases/download/$VERSION/$filename}"
    else
        read -r filename asset_digest_hex asset_download_url cache_dir < <(
            fetch_asset_metadata | awk -F= '
                $1 == "filename" { filename = $2 }
                $1 == "asset_digest_hex" { digest = $2 }
                $1 == "asset_download_url" { download_url = $2 }
                $1 == "cache_dir" { cache_dir = $2 }
                END { printf "%s %s %s %s\n", filename, digest, download_url, cache_dir }
            '
        )
    fi

    log_info "installing $APP $VERSION"
    log_info "asset: $filename"
    log_info "cache: $cache_dir"

    archive_path="$cache_dir/$filename"
    case "$filename" in
        *.tar.gz)
            require_cmd tar
            ;;
        *.zip)
            require_cmd unzip
            ;;
    esac
    require_cmd curl

    runner_temp="${RUNNER_TEMP:-/tmp}"
    mkdir -p "$runner_temp"
    tmp_dir=$(mktemp -d "$runner_temp/opencode-download.XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT
    tmp_extract_dir="$tmp_dir/extract"

    if [ -f "$archive_path" ]; then
        log_info "found cached archive: $archive_path"
        if verify_cached_archive "$archive_path" "$asset_digest_hex"; then
            log_info "verified cached archive"
        else
            log_warn "removing invalid cached archive"
            rm -f "$archive_path"
        fi
    fi

    if [ ! -f "$archive_path" ]; then
        download_dir="$tmp_dir/download"
        mkdir -p "$download_dir"
        download_archive "$download_dir" "$filename" "$asset_download_url"
        downloaded_archive="$download_dir/$filename"

        if [ ! -f "$downloaded_archive" ]; then
            log_error "expected downloaded archive not found: $downloaded_archive"
            exit 1
        fi

        if ! verify_cached_archive "$downloaded_archive" "$asset_digest_hex"; then
            log_error "downloaded archive sha256 mismatch for $filename"
            exit 1
        fi
        log_info "verified downloaded archive"

        mkdir -p "$cache_dir"
        mv "$downloaded_archive" "$archive_path"
        log_info "stored archive in cache"
    fi

    install_from_archive "$archive_path" "$INSTALL_DIR" "$tmp_extract_dir"

    if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$INSTALL_DIR" >> "$GITHUB_PATH"
        log_info "added $INSTALL_DIR to GITHUB_PATH"
    fi
}

main() {
    local mode="${1:-}"

    case "$mode" in
        metadata)
            ;;
        install)
            ;;
        -h|--help|help|"")
            usage
            exit 0
            ;;
        *)
            log_error "unknown mode: $mode"
            usage >&2
            exit 1
            ;;
    esac

    if [ -z "$VERSION" ]; then
        log_error "OPENCODE_VERSION is required"
        exit 1
    fi

    case "$mode" in
        metadata)
            fetch_asset_metadata
            ;;
        install)
            install_release
            ;;
    esac
}

main "$@"
