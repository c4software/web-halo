#!/usr/bin/env bash
# Browser version of Halo, entirely through Docker: build, local hosting with
# the local signaling service, and a bundle to run on another machine
# (see README_WEB.md).

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./halo-web.sh [command] [options]

Commands:
  all [--iso IMAGE]     build, then serve (the default)
  build [--iso IMAGE]   extract maps/ if needed and build the browser version
  serve                 serve the game and the signaling service locally
                        (http://127.0.0.1:8765/build/web/halo.html)
  stop                  stop the local services
  package [--url ORIGIN] [--output DIR]
                        make a bundle to run on another machine without
                        rebuilding (default output: dist/halo-web); the game
                        data is not included, the target mounts it
                        --url ORIGIN: public address given by your reverse
                        proxy (e.g. https://halo.example.lan), written to
                        the bundle's .env; without it, the game is used at
                        http://127.0.0.1:8765 on the target itself

Options:
  --iso IMAGE           Xbox disc image to extract maps/ from (default: the
                        only .iso in the repository root, when assets/maps
                        is absent)
  -h, --help            show this help
EOF
}

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repository"

export HOST_UID=${HOST_UID:-$(id -u)}
export HOST_GID=${HOST_GID:-$(id -g)}

# The bundle's files (compose.yaml, env.example, start.sh, README.md).
BUNDLE_DIR=docker/bundle
# Images the bundle's compose.yaml uses, saved into the bundle.
BUNDLE_IMAGES=(halo-signaling python:3.12-slim)

compose() {
    docker compose "$@"
}

fail() {
    echo "halo-web.sh: $*" >&2
    exit 1
}

# --- build -------------------------------------------------------------------

extract_maps() {
    local iso=$1 iso_path container_iso
    local -a mount=()

    [ -f assets/maps/ui.map ] && return
    if [ -z "$iso" ]; then
        shopt -s nullglob
        local -a images=(*.iso *.xiso)
        shopt -u nullglob
        [ ${#images[@]} -eq 1 ] || fail "assets/maps is missing; pass --iso /path/to/Halo.iso"
        iso=${images[0]}
    fi
    [ -f "$iso" ] || fail "disc image does not exist: $iso"

    # The repository is mounted at /src; an image outside it is mounted apart.
    iso_path=$(realpath "$iso")
    case "$iso_path" in
        "$repository"/*) container_iso="/src/${iso_path#"$repository"/}" ;;
        *)
            container_iso="/iso/$(basename "$iso_path")"
            mount=(-v "$iso_path:$container_iso:ro")
            ;;
    esac
    echo "==> Extracting maps/ from $iso"
    compose run --rm "${mount[@]}" web \
        python3 tools/xiso_extract.py "$container_iso" --output assets/maps
}

build() {
    local iso=$1

    echo "==> Build image"
    compose build web
    extract_maps "$iso"

    # The web UI images (port/web/assets) are not published with the
    # sources, but the build needs the folder: without them the menu shows
    # broken images only.
    if [ ! -d port/web/assets ]; then
        echo "==> port/web/assets is missing; creating it empty (no UI images)"
        mkdir -p port/web/assets
    fi

    # Same configuration as tools/web_run.py.
    if ! { grep -q "build web: phony" build.ninja \
            && grep -q -- "-DHALO_RELEASE" build.ninja \
            && grep -q -- "-sASSERTIONS=0" build.ninja; } 2>/dev/null; then
        echo "==> Configuring"
        compose run --rm web python3 configure.py --release --pgo=off --lto=off
    fi
    echo "==> Building"
    compose run --rm web ninja web

    # The page talks to the local signaling service instead of the author's
    # Cloudflare services, and loads no Turnstile script.
    echo "==> Pointing the page at the local signaling service"
    compose run --rm web python3 docker/web/localize_page.py build/web/halo.html
}

require_build() {
    local output
    for output in halo.html halo.js halo.wasm; do
        [ -f "build/web/$output" ] || fail "no browser build (build/web/$output); run ./halo-web.sh build"
    done
}

# --- local hosting -----------------------------------------------------------

serve() {
    require_build
    [ -f assets/maps/ui.map ] || fail "no game data (assets/maps); run ./halo-web.sh build"
    echo "==> Serving on http://127.0.0.1:8765/build/web/halo.html (Ctrl-C to stop)"
    compose up --build serve signaling
}

# --- bundle for another machine ----------------------------------------------

package() {
    local url=$1 output=$2
    local www="$output/www"

    require_build
    case "$url" in
        ""|http://*|https://*) ;;
        *) fail "--url must start with https:// (or http://)" ;;
    esac
    if [ -e "$output" ]; then
        [ -f "$output/compose.yaml" ] || fail "$output exists and is not a bundle"
        echo "==> Replacing $output"
        rm -rf "$output"
    fi
    # maps/ (1.7 GiB) is not copied: the target mounts it as a volume
    # (HALO_MAPS in .env), at this empty mount point.
    mkdir -p "$www/build/web" "$www/assets/maps"

    echo "==> Game files"
    cp -a build/web/halo.html build/web/halo.js build/web/halo.wasm "$www/build/web/"
    [ -d build/web/assets ] && cp -a build/web/assets "$www/build/web/"
    cp -a tools/web_serve.py "$output/"
    # The bundle's server runs as nobody.
    chmod -R a+rX "$www" "$output/web_serve.py"

    echo "==> Docker images (${BUNDLE_IMAGES[*]})"
    compose build signaling
    local image
    for image in "${BUNDLE_IMAGES[@]}"; do
        docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
    done
    docker save "${BUNDLE_IMAGES[@]}" | gzip > "$output/images.tar.gz"

    echo "==> Configuration"
    cp -a "$BUNDLE_DIR/compose.yaml" "$BUNDLE_DIR/start.sh" "$BUNDLE_DIR/README.md" "$output/"
    sed "s|^HALO_PUBLIC_ORIGIN=.*|HALO_PUBLIC_ORIGIN=$url|" "$BUNDLE_DIR/env.example" > "$output/.env"

    echo "==> Bundle ready: $output ($(du -sh "$output" | cut -f1))"
    echo "    Copy it to the target machine (e.g. rsync -a $output/ target:halo-web/),"
    echo "    set HALO_MAPS in its .env, then run ./start.sh there."
}

# --- command line ------------------------------------------------------------

command=all
case "${1:-}" in
    all|build|serve|stop|package) command=$1; shift ;;
    -h|--help) usage; exit 0 ;;
esac

iso=""
url=""
output="dist/halo-web"
while [ $# -gt 0 ]; do
    case "$1" in
        --iso) iso=${2:?--iso needs a path}; shift 2 ;;
        --url) url=${2:?--url needs an address}; shift 2 ;;
        --output) output=${2:?--output needs a directory}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "halo-web.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$command" in
    all) build "$iso"; serve ;;
    build) build "$iso" ;;
    serve) serve ;;
    stop) compose down ;;
    package) package "$url" "$output" ;;
esac
