# Browser version with Docker

This environment builds the browser version (`ninja web`) without installing
Emscripten or ninja on the computer. It can also serve the game with a local
signaling service for online lobbies, and make a bundle that runs on another
machine without a rebuild.

## Files

| File | Purpose |
| --- | --- |
| `halo-web.sh` | The script that does everything: build, local servers, bundle for another machine. |
| `compose.yaml` | The services `web` (build commands), `serve` (local server) and `signaling`. |
| `docker/web/Dockerfile` | The build image: `emscripten/emsdk:6.0.10` and `ninja-build`. |
| `docker/web/localize_page.py` | Points the built page at the local signaling service. |
| `docker/signaling/` | The image of the signaling service (`services/signaling`), run with `wrangler dev`. |
| `docker/bundle/` | The files of the bundle: `compose.yaml`, `env.example`, `start.sh`, `README.md`. |

- The repository is mounted at `/src`. `build/` stays on the computer.
- The containers run with the UID and GID of the user (1000:1000 by default;
  set `HOST_UID` and `HOST_GID` to change them). Thus root does not own this
  folder.
- The Emscripten cache is kept in the `emscripten-cache` volume. The first
  link downloads and compiles SDL3 (3.4.16, `port/web/halo_sdl3.py`). Later
  links use the cache.
- The project does not pin an Emscripten version. To use a different one,
  change the `EMSDK_VERSION` argument of the Dockerfile.

## Usage

```sh
./halo-web.sh                     # build, then serve locally
./halo-web.sh build               # build the browser version
./halo-web.sh serve               # serve the game and the signaling service
./halo-web.sh stop                # stop the local services
./halo-web.sh package [--url https://halo.example.lan] [--output DIR]
```

`build` does these steps:

1. It builds the Docker image.
2. If `build.ninja` does not have the release web target, it runs
   `configure.py --release --pgo=off --lto=off`, as `tools/web_run.py` does.
3. It runs `ninja web`.
4. It points the page at the local signaling service.
5. It copies `port/web/coi-serviceworker.js` next to the page, which loads it.

`serve` then serves the game at
<http://127.0.0.1:8765/build/web/halo.html>. The server sends the COOP and
COEP headers that WebAssembly threads need. Use a current desktop browser with
WebGL 2, WebAssembly threads and cross-origin isolation. Chrome is
recommended.

## Game data

The build does not include game data, and the servers do not serve it. On
first use, the page asks each player for an Xbox disc image (`.xiso` or
`.iso`) made from their own copy of Halo: Combat Evolved. The browser copies
the maps to its origin-private storage and reads them from there. The disc
image never leaves the player's device. Thus `halo-web.sh` does not extract
the maps, and the bundle does not mount them.

## Local multiplayer

All services run on the computer. No Cloudflare service is necessary.

- The `signaling` service runs `services/signaling` with `wrangler dev` at
  <http://127.0.0.1:8787>. `wrangler dev` runs the Workers runtime (`workerd`)
  and simulates Durable Objects, KV and rate limits locally. The state is in
  the `signaling-data` volume. The service only connects the browsers
  (WebRTC signaling). The game traffic goes directly between the browsers.
- After the build, `docker/web/localize_page.py` changes
  `build/web/halo.html`: it empties the signaling URL and the Turnstile site
  key, and removes the Turnstile script. Without a signaling URL, a page on
  `127.0.0.1` or `localhost` uses `http://<host>:8787`.
- The service runs in `development` mode, without Turnstile. It makes new
  secrets (`ROOM_ID_SECRET`, `ABUSE_ID_SECRET`, `ADMIN_TOKEN`) at each start,
  unless the environment gives them.
- The service accepts the origins `http://127.0.0.1:8765` and
  `http://localhost:8765`. Set `HALO_ALLOWED_ORIGINS` and
  `HALO_PUBLIC_GAME_URL` to change them.
- The service still gives the Cloudflare STUN server
  (`stun.cloudflare.com`, in `services/signaling/src/turn.ts`) to the
  browsers. Browsers on the same computer or network do not need it.

## Bundle for another machine

`./halo-web.sh package` makes `dist/halo-web/` (approximately 540 MB). Copy it
to the target machine. The target needs only Docker with Compose; it does not
compile anything.

- `www/`: `halo.html`, `halo.js`, `halo.wasm`, `coi-serviceworker.js` and
  the UI images.
- `images.tar.gz`: the Docker images `halo-signaling` and `python:3.12-slim`.
  `start.sh` loads them, so the target does not need Internet access.
- `compose.yaml`, `start.sh` and `README.md`, from `docker/bundle/`, and
  `.env`, from `docker/bundle/env.example`.

`HALO_PUBLIC_ORIGIN` in `.env` selects one of two uses:

- **Empty**: the game is used on the target itself, at
  <http://127.0.0.1:8765/build/web/halo.html>.
- **A public address** (`--url`, for example `https://halo.example.lan`): a
  reverse proxy serves the game over HTTPS. The proxy sends `/v1/*` (with
  WebSockets) to `HALO_SIGNALING_PORT` and all other paths to
  `HALO_WEB_PORT`, and keeps the `Host` header. The signaling service then
  gives `wss://` URLs on that address.

Outside `localhost`, browsers require HTTPS: the game needs cross-origin
isolation. `HALO_BIND` (`127.0.0.1` by default) is the listen address. Use
`0.0.0.0` if the reverse proxy runs on a different machine.

### Deploy

1. Copy the bundle:

   ```sh
   rsync -a dist/halo-web/ server:halo-web/
   ```

2. On the server, set `HALO_PUBLIC_ORIGIN` (and `HALO_BIND` if necessary) in
   `.env`.
3. On the server, start the services:

   ```sh
   ./start.sh
   ```

4. Configure the reverse proxy as given above. The game is then at
   `HALO_PUBLIC_ORIGIN/build/web/halo.html`.

To update, build and package again, then copy the bundle without the `.env`
of the server, and start the services again:

```sh
./halo-web.sh build && ./halo-web.sh package
rsync -a --exclude .env dist/halo-web/ server:halo-web/
ssh server halo-web/start.sh
```

The Docker images in the bundle are for the architecture of the computer that
made the bundle (for example x86-64). A server with a different architecture
(for example ARM) cannot start them. The game files do not depend on the
architecture.

## Isolation

The containers run with the minimum privileges:

- a user that is not root;
- no Linux capabilities (`cap_drop: [ALL]`);
- `no-new-privileges`: no privilege escalation through setuid or `sudo`;
- a read-only image file system for the build service. Only `/src`, the
  Emscripten cache and `/tmp` (tmpfs) are writable;
- the `serve` service mounts the repository read-only. The published ports
  listen only on `127.0.0.1`;
- no Docker socket, and the default seccomp profile.

The `web` service keeps network access, because the first link downloads
SDL3. It can write to the repository (`build/`, `build.ninja`).

## Manual use

From the repository root:

```sh
# 1. Configure and build (the same options as tools/web_run.py)
docker compose run --rm web sh -c 'python3 configure.py --release --pgo=off --lto=off && ninja web'

# 2. Use the local signaling service
docker compose run --rm web python3 docker/web/localize_page.py

# 3. Copy the script that the page loads from its own folder
cp port/web/coi-serviceworker.js build/web/

# 4. Serve the game and the signaling service
docker compose up serve signaling
```

## Notes

- `build.ninja` is generated in the container and refers to the `emcc` of the
  image. To build outside Docker, run `configure.py` again.
- The script runs `configure.py` and `ninja` directly, not
  `tools/web_run.py`. That script opens a browser and makes the server listen
  only on 127.0.0.1, which does not work from a container.
- The web UI images (`port/web/assets`) are not in the repository, but the
  build needs the folder. If the folder does not exist, `halo-web.sh` makes it
  empty. The menu then shows broken images; the game does not need them. The
  `assets/` pattern of `.gitignore` excludes this folder.
