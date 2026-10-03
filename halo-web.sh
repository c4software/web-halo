#!/usr/bin/env bash
# Browser version of Halo, entirely through Docker: build, local hosting with
# the local signaling service, and a bundle to run on another machine
# (see README_WEB.md).

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./halo-web.sh [command] [options]

Commands:
  all                   build, then serve (the default)
  build                 build the browser version
  serve                 serve the game and the signaling service locally
                        (http://127.0.0.1:8765/build/web/halo.html)
  stop                  stop the local services
  package [--url ORIGIN] [--output DIR]
                        make a bundle to run on another machine without
                        rebuilding (default output: dist/halo-web)
                        --url ORIGIN: public address given by your reverse
                        proxy (e.g. https://halo.example.lan), written to
                        the bundle's .env; without it, the game is used at
                        http://127.0.0.1:8765 on the target itself

Options:
  -h, --help            show this help

No game data is built in or served: on first use, each player chooses an
XISO of their own copy of Halo in the browser, which keeps the maps locally.
EOF
}

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repository"

# The containers run as the host user, so that this user owns build/. With
# rootless Docker, root in a container is the host user.
if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    export HOST_UID=${HOST_UID:-0}
    export HOST_GID=${HOST_GID:-0}
else
    export HOST_UID=${HOST_UID:-$(id -u)}
    export HOST_GID=${HOST_GID:-$(id -g)}
fi

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

build() {
    echo "==> Build image"
    compose build web

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

    # The page loads this script from its own folder (port/web/shell.html).
    cp port/web/coi-serviceworker.js build/web/
}

require_build() {
    local output
    for output in halo.html halo.js halo.wasm coi-serviceworker.js; do
        [ -f "build/web/$output" ] || fail "no browser build (build/web/$output); run ./halo-web.sh build"
    done
}

# --- local hosting -----------------------------------------------------------

serve() {
    require_build
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
    mkdir -p "$www/build/web"

    echo "==> Game files"
    cp -a build/web/halo.html build/web/halo.js build/web/halo.wasm \
        build/web/coi-serviceworker.js "$www/build/web/"
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
    echo "    then run ./start.sh there."
}

# --- command line ------------------------------------------------------------

command=all
case "${1:-}" in
    all|build|serve|stop|package) command=$1; shift ;;
    -h|--help) usage; exit 0 ;;
esac

url=""
output="dist/halo-web"
while [ $# -gt 0 ]; do
    case "$1" in
        --url) url=${2:?--url needs an address}; shift 2 ;;
        --output) output=${2:?--output needs a directory}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "halo-web.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$command" in
    all) build; serve ;;
    build) build ;;
    serve) serve ;;
    stop) compose down ;;
    package) package "$url" "$output" ;;
esac
