#!/usr/bin/env bash
# install.sh — one-command BawtHub tenant install / reapply (TASK-349).
#
#   curl -fsSL https://raw.githubusercontent.com/bawthub/bawthub/main/deploy/install.sh | bash
#
# Needs only Docker Engine + the Compose v2 plugin, git and curl. It:
#   1. checks prerequisites and fails with the exact fix,
#   2. clones (or fast-forwards) the BawtHub repo into $BAWTHUB_DIR,
#   3. creates deploy/tenant.env from the example, once — an existing manifest
#      is never overwritten,
#   4. runs deploy/bootstrap.sh up (generate the database password on first
#      run, pull pinned images, migrate, start, verify),
#   5. prints the URL; a fresh tenant opens on /setup.
# Re-running it is safe: same manifest, secrets and settings, newer
# installer/compose/migrations from REF. When the new release has newer image
# pins, an interactive run offers to update (`update` applies them without
# asking). Only pins this repository published move; custom pins are kept and
# turned-off components stay off. A failed update restores the previous pins.
#
# Env: BAWTHUB_DIR (default ~/bawthub), BAWTHUB_REF (default main),
#      BAWTHUB_REPO (default https://github.com/bawthub/bawthub.git).
# Private repo/images: set GH_TOKEN (read access); it is used for the clone and
# a temporary `docker login ghcr.io`; it is never written to disk persistently.
#
# Release bundle (no GitHub or registry login): run the install.sh inside an
# unpacked bundle directory (or set BAWTHUB_BUNDLE to it). The bundle carries a
# checksummed source snapshot of one release and that release's published
# images. The snapshot replaces the git download, and the images are served
# for this run only from a loopback registry, by the same digests the release
# pins. Update / repair, rollback and settings behave exactly as above.
set -Eeuo pipefail

DIR="${BAWTHUB_DIR:-$HOME/bawthub}"
REF="${BAWTHUB_REF:-main}"
REPO="${BAWTHUB_REPO:-https://github.com/bawthub/bawthub.git}"
LOG_FILE=""
TEMP_DIR=""
AUTH_CONFIG=""
INTERACTIVE=0
ACTION=install
WIPE=0
CONFIRM=""
SETTINGS=()
PASSKEY_HOST_CHANGED=0
CORE_ONLY=0
VERBOSE=0
BOT_PACK=""
FIRST_INSTALL=0
DOCKER_ROOT=""
DOCKER_FREE=""
SHORT_DISK=0
SHORT_MEMORY=0
BUNDLE="${BAWTHUB_BUNDLE:-}"
SOURCE_ONLY=0
REGISTRY_CONTAINER=""
# Serves the bundle's images; pulled anonymously from Docker Hub by digest.
BUNDLE_REGISTRY_IMAGE="docker.io/library/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"

log() { printf 'install: %s\n' "$*" >&2; }
detail() { printf '%s\n' "$*" >> "$LOG_FILE"; }
die() {
  printf '\nCould not finish: %s\n' "$*" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf 'Details: %s\n' "$LOG_FILE" >&2
    tail -n 12 "$LOG_FILE" >&2
  fi
  printf 'Fix the issue above, then run the same command again.\n' >&2
  exit 1
}
cleanup() {
  [[ -z "$REGISTRY_CONTAINER" ]] || docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
  [[ -z "$AUTH_CONFIG" ]] || rm -rf -- "$AUTH_CONFIG"
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  return 0
}
trap cleanup EXIT
trap 'die "An installer command failed (line $LINENO). Check the details below."' ERR

header() {
  local columns="${COLUMNS:-80}" color="" reset=""
  if (( TTY_AVAILABLE )) && [[ -z "${COLUMNS:-}" ]]; then
    columns="$(stty size <&3 2>/dev/null | awk '{print $2}')" || columns=80
  fi
  [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
  if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-}" != dumb ]]; then
    color=$'\033[1;36m'; reset=$'\033[0m'
  fi
  printf '%s' "$color"
  if (( columns < 72 )); then
    printf '\n  [ BawtHub ]\n'
  else
    printf '%s\n' '   ____                 _   _   _       _'
    printf '%s\n' '  | __ )  __ ___      _| |_| | | |_   _| |__'
    printf '%s\n' '  |  _ \ / _` \ \ /\ / / __| |_| | | | | _ \ '
    printf '%s\n' '  | |_) | (_| |\ V  V /| |_|  _  | |_| | |_) |'
    printf '%s\n' '  |____/ \__,_| \_/\_/  \__|_| |_|\__,_|_.__/'
  fi
  printf '%s  Your bots. Your space.\n\n' "$reset"
}

ask() {
  printf '%s' "$1" >&3
  IFS= read -r REPLY <&3 || die "No answer received. Reopen a terminal and try again."
}

usage() {
  printf '%s\n' 'Usage: install.sh [install|update|configure|uninstall] [options]'
  printf '%s\n' '  install --core-only: first install with chat and bots only (no voice or agent tools)'
  printf '%s\n' '  install --bot-pack FILE: add the bots in a pack exported from another install'
  printf '%s\n' '  install or update --bundle DIR: use images from a local BawtHub release bundle'
  printf '%s\n' '  install or update --verbose: also show Docker layer progress'
  printf '%s\n' '  update: install, applying newer published image pins without asking'
  printf '%s\n' '  configure: --voice pocket|off --microphone on|off --agent-tools on|off'
  printf '%s\n' '             --port NUMBER --lan-address HOST --access signin|trusted-lan'
  printf '%s\n' '  uninstall: --wipe --confirm TENANT (otherwise keeps all data)'
  printf '%s\n' '  No arguments: interactive menu when a terminal is available.'
}

# ── 1. Preflight ───────────────────────────────────────────────────────────
preflight() {
local os arch disk probe memory
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in Darwin|Linux) ;; *) die "Use macOS or Linux with Docker installed." ;; esac
case "$arch" in x86_64|amd64|aarch64|arm64) ;; *) die "This computer needs a supported Intel/AMD 64-bit or ARM64 processor." ;; esac
command -v docker >/dev/null || die "Install Docker Desktop on Mac, or Docker Engine on Linux, then start it."
docker info >/dev/null 2>&1 || die "Start Docker Desktop (Mac) or the Docker service (Linux), and check that 'docker info' works for your user."
docker compose version >/dev/null 2>&1 || die "Install the Docker Compose v2 plugin, or update Docker Desktop."
[[ "$ACTION" == install || "$ACTION" == update ]] || return 0
for bin in git curl; do
  # A bundle (or a bundle-installed copy) replaces the git download.
  [[ "$bin" != git || -d "$DIR/.git" || ( -z "$BUNDLE" && ! -f "$DIR/$SOURCE_MARK" ) ]] || continue
  command -v "$bin" >/dev/null || die "$bin is missing (Ubuntu: sudo apt-get install -y $bin)"
done
probe="$DIR"
while [[ ! -d "$probe" && "$probe" != / ]]; do probe="$(dirname "$probe")"; done
disk="$(df -Pk "$probe" | awk 'END {print $4}')"
[[ "$disk" =~ ^[0-9]+$ ]] || die "Cannot check free disk space at $probe. Check that the disk is available."
(( disk >= 5 * 1024 * 1024 )) || die "Free at least 5 GB on the installation disk."
if [[ -f "${TENANT_ENV:-$DIR/deploy/tenant.env}" ]]; then
  (( ! CORE_ONLY )) || die "--core-only is for a first install. Use Change settings to turn parts off on this one."
else
  FIRST_INSTALL=1
fi
# Images live in Docker's own storage, which may be another disk than the
# checkout (or, with Docker Desktop, inside its virtual disk). Gate on it only
# when this computer can measure it. A first install downloads the core images
# (about 12 GB measured); an existing install already has them.
docker_storage
if (( FIRST_INSTALL )) && [[ -n "$DOCKER_FREE" ]] && (( DOCKER_FREE < 15 * 1024 * 1024 )); then
  die "Free at least 15 GB where Docker keeps images ($DOCKER_ROOT has $(gib $((DOCKER_FREE * 1024)))): chat and bots alone take about 12 GB."
fi
memory="$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)"
if [[ "$memory" =~ ^[0-9]+$ ]]; then
  (( memory >= 2 * 1024 * 1024 * 1024 )) || die "Give Docker at least 2 GB of memory (4 GB or more recommended)."
fi
hardware_report "$os" "$disk" "$memory"
}

# ── Hardware report ────────────────────────────────────────────────────────
# Read-only: nothing is uploaded and no Docker setting is changed. Each part
# is rated on its own, so a small machine still installs the core.
# Figures measured on a 16 GB Apple M4 MacBook Air with Docker Desktop at 8 GB
# (the default stack idles at about 4.1 GB inside Docker):
#   core (app, agent bridge, embeddings, frontend, ops, database)  2.0 GB idle, 12 GB of images
#   voice replies (Pocket)  1.3 GB peak, about 3 CPUs while speaking, first
#                           audio in 0.1 s, about 3x faster than real time; 6.8 GB of images
#   agent tools (browser, crawler)  0.7 GB idle, 11 GB of images
#   dictation (CPU)  capped at 0.75 GB; not yet verified on Apple Silicon
#   coding previews  each house may use up to half of Docker's memory
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1073741824 }'; }

# Sets DOCKER_ROOT and DOCKER_FREE (KB) when Docker's image storage is a known
# local directory: a Linux engine on a local socket using overlay2. Docker
# Desktop, remote engines and the containerd image store leave both empty.
docker_storage() {
  local endpoint root
  DOCKER_ROOT=""; DOCKER_FREE=""
  [[ "$(uname -s)" == Linux ]] || return 0
  # Locality comes from the effective endpoint, never a context's name.
  endpoint="${DOCKER_HOST:-}"
  [[ -n "$endpoint" ]] || endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  case "$endpoint" in unix://*) ;; *) return 0 ;; esac
  case "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)" in *"Docker Desktop"*) return 0 ;; esac
  # Only the classic overlay2 driver keeps images under DockerRootDir. The
  # containerd image store (the default on new Docker Engine 29 installs)
  # keeps them in containerd's own root, which Docker doesn't report.
  [[ "$(docker info --format '{{.Driver}}' 2>/dev/null || true)" == overlay2 ]] || return 0
  case "$(docker info --format '{{.DriverStatus}}' 2>/dev/null || true)" in *containerd*) return 0 ;; esac
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ "$root" == /* && -d "$root" ]] || return 0
  DOCKER_FREE="$(df -Pk "$root" 2>/dev/null | awk 'END {print $4}')"
  if [[ "$DOCKER_FREE" =~ ^[0-9]+$ ]]; then DOCKER_ROOT="$root"; else DOCKER_FREE=""; fi
}

capability() { # NAME STATUS DETAIL; notes any part that is not fully available
  case "$2" in constrained|"not recommended") SHORT_ON_DOCKER=1 ;; esac
  case "$1:$2" in "Voice replies:not recommended"|"Agent web tools:not recommended") SHORT_MEMORY=1 ;; esac
  if [[ -n "$3" ]]; then printf '    %-16s %-16s %s\n' "$1" "$2" "$3"
  else printf '    %-16s %s\n' "$1" "$2"; fi
}

hardware_report() {
  local os="$1" disk="$2" memory="$3" host="" chip="" version="" cpus="" engine="" gb resources
  local docker_line voice dictation tools previews gpu
  gb=$((1024 * 1024 * 1024))
  SHORT_ON_DOCKER=0; SHORT_DISK=0; SHORT_MEMORY=0
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || true)"
  engine="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
  if [[ "$os" == Darwin ]]; then
    version="macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
    host="$(sysctl -n hw.memsize 2>/dev/null || true)"
    resources="Docker Desktop > Settings > Resources"
  else
    version="Linux $(uname -r 2>/dev/null || true)"
    chip="$(awk -F': *' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)"
    host="$(awk '/^MemTotal:/ { print $2 * 1024; exit }' /proc/meminfo 2>/dev/null || true)"
    resources="your Docker settings"
  fi
  [[ "$host" =~ ^[0-9]+$ ]] || host=""
  [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=""
  [[ "$memory" =~ ^[0-9]+$ ]] || memory=""
  printf '\n  This computer\n'
  printf '    %s, %s (%s)' "$version" "${chip:-unknown processor}" "$(uname -m)"
  [[ -z "$host" ]] || printf ', %s memory' "$(gib "$host")"
  printf '\n'
  docker_line="Docker: ${memory:+$(gib "$memory") memory}${memory:+, }${cpus:-?} CPUs${engine:+ ($engine)}"
  printf '    %s; %s free for the installation\n' "$docker_line" "$(gib $((disk * 1024)))"
  # Images: core about 12 GB; voice replies and agent tools about 18 GB more.
  if [[ -z "$DOCKER_FREE" ]]; then
    printf '    Image storage: not visible from here; check %s.\n' \
      "$([[ "$os" == Darwin ]] && echo "the disk usage limit in $resources" || echo "free space where Docker keeps images")"
    printf '    Chat and bots need about 12 GB of images; every part about 31 GB.\n'
  else
    printf '    Image storage: %s free in %s\n' "$(gib $((DOCKER_FREE * 1024)))" "$DOCKER_ROOT"
    if (( DOCKER_FREE < 32 * 1024 * 1024 )); then
      printf '    Every part together needs about 31 GB of images; voice replies and agent tools take about 18 GB of it.\n'
      SHORT_DISK=1
    fi
  fi
  if [[ -z "$memory" ]]; then
    printf '  Docker did not report its memory, so the parts below are not rated.\n\n'
    return 0
  fi
  printf '  What it can run (Docker memory counts, not the computer'"'"'s)\n'
  # Core: measured 2.0 GB idle; 2 GB is the floor checked above.
  if (( memory < 3 * gb )); then
    capability "Chat and bots" constrained "starts, but leaves no room for growth; give Docker 4 GB or more in $resources"
  else
    capability "Chat and bots" available ""
  fi
  # Voice replies: core plus 1.3 GB peak and about 3 CPUs while speaking.
  if (( memory < 3 * gb )); then
    voice="not recommended:give Docker 4 GB or more in $resources, or turn voice off in Change settings"
  elif (( memory < 4 * gb )) || [[ -n "$cpus" && "$cpus" -lt 4 ]]; then
    voice="constrained:may speak slower than real time; 4 GB and 4 CPUs for Docker recommended in $resources"
  else
    voice="available:"
  fi
  capability "Voice replies" "${voice%%:*}" "${voice#*:}"
  # Dictation: the CPU recognizer is not yet verified on ARM (Apple Silicon).
  if [[ "$engine" == aarch64 || "$engine" == arm64 ]]; then
    dictation="experimental:not yet verified on ARM; turn it on in Change settings to try it"
  elif (( memory < 4 * gb )); then
    dictation="constrained:needs 0.75 GB more; 4 GB for Docker recommended in $resources"
  else
    dictation="available:turn it on in Change settings"
  fi
  capability "Dictation" "${dictation%%:*}" "${dictation#*:}"
  # Agent tools: 0.7 GB idle and more while a page loads.
  if (( memory < 4 * gb )); then
    tools="not recommended:turn agent tools off in Change settings, or give Docker 6 GB or more"
  elif (( memory < 6 * gb )); then
    tools="constrained:browsing may be slow; 6 GB for Docker recommended in $resources"
  else
    tools="available:"
  fi
  capability "Agent web tools" "${tools%%:*}" "${tools#*:}"
  # Coding previews: measured comfortable at an 8 GB Docker allocation
  # (reported as about 7.7 GB). Their build-time peak is not yet measured.
  if (( memory < 6 * gb )); then
    previews="not recommended:set HOUSES=0 in tenant.env, or give Docker 8 GB or more"
  elif (( memory < 7 * gb + gb / 2 )); then
    previews="constrained:large previews may be slow; 8 GB for Docker recommended in $resources"
  else
    previews="available:"
  fi
  capability "Coding previews" "${previews%%:*}" "${previews#*:}"
  if [[ "$os" == Darwin ]]; then
    gpu="not supported:Docker on Mac can't use the Apple GPU; voice uses the CPU instead"
  elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    gpu="possible:an NVIDIA GPU is present; use a GPU voice backend with VOICE=external"
  else
    gpu="not supported:no NVIDIA GPU found; voice uses the CPU instead"
  fi
  capability "GPU voice" "${gpu%%:*}" "${gpu#*:}"
  if (( SHORT_ON_DOCKER )) && [[ -n "$host" ]] && (( host >= 2 * memory )); then
    printf '  Docker has %s of this computer'"'"'s %s. Raising it in %s helps the optional parts.\n' \
      "$(gib "$memory")" "$(gib "$host")" "$resources"
  fi
  printf '  Each part is rated on its own; turn any optional part on or off later with Change settings.\n\n'
}

# A new manifest starts with voice replies and agent tools on. Before the
# first download, offer chat and bots only when this computer is short for
# them: one of their images running out of space would stop the same pull that
# starts the core.
first_install_parts() {
  local reason=""
  # Short storage outranks short memory: only storage can stop the pull.
  if (( SHORT_DISK )); then reason="Docker's image storage is short for every part"
  elif (( SHORT_MEMORY )); then reason="Docker's memory is short for voice replies or agent tools"
  fi
  if (( ! CORE_ONLY )) && [[ -n "$reason" ]]; then
    if (( INTERACTIVE )); then
      ask "  $reason. Start with chat and bots only, and add the rest later in Change settings? [Y/n]: "
      case "$REPLY" in ""|y|Y|yes|Yes) CORE_ONLY=1 ;; esac
    elif (( SHORT_DISK )); then
      CORE_ONLY=1
    else
      log "$reason; installing them anyway. Run with --core-only to leave them out."
    fi
  fi
  (( CORE_ONLY )) || return 0
  put_setting VOICE off
  put_setting AGENT_TOOLS 0
  log "Starting with chat and bots only${reason:+ ($reason)}. Turn on voice replies and agent tools later with Change settings."
}

private_access() {
if [[ -n "${GH_TOKEN:-}" ]]; then
  # GHCR auth goes in a throwaway Docker config, removed on any exit, so the
  # token never reaches the caller's ~/.docker or a credential helper. The auth
  # entry is written directly (no `docker login`): a config that already holds
  # auths skips Docker's native credential-helper autodetection.
  # A temp config has no context store, so carry the active endpoint as
  # DOCKER_HOST, and refuse TLS contexts whose material can't be carried.
  if [[ -z "${DOCKER_HOST:-}" ]]; then
    ctx="$(docker context show 2>/dev/null || echo default)"
    if [[ "$ctx" != default ]]; then
      [[ -z "$(docker context inspect "$ctx" --format '{{range .TLSMaterial}}x{{end}}' 2>/dev/null)" ]] || \
        die "Docker context '$ctx' uses TLS; set DOCKER_HOST/DOCKER_TLS_VERIFY/DOCKER_CERT_PATH for it, or log in to ghcr.io yourself and run without GH_TOKEN"
      DOCKER_HOST="$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}')" || die "cannot read Docker context '$ctx'"
      export DOCKER_HOST
    fi
  fi
  # CLI plugins (compose) can live under the caller's config dir, as with
  # Docker Desktop on macOS, so list the directories they load from now and
  # keep them visible to the temp config.
  plugin_dirs=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    d="${p%/*}"; d="${d//\\/\\\\}"; d="${d//\"/\\\"}"   # JSON string escape
    plugin_dirs="$plugin_dirs${plugin_dirs:+,}\"$d\""
  done < <(docker info --format '{{range .ClientInfo.Plugins}}{{.Path}}{{println}}{{end}}' 2>/dev/null || true)
  unset DOCKER_CONTEXT
  DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
  AUTH_CONFIG="$DOCKER_CONFIG"
  ( umask 077; printf '{"auths":{"ghcr.io":{"auth":"%s"}},"cliPluginsExtraDirs":[%s]}\n' \
      "$(printf 'token:%s' "$GH_TOKEN" | base64 | tr -d '\n')" "$plugin_dirs" > "$DOCKER_CONFIG/config.json" )
  docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon after switching to a temporary config"
  docker compose version >/dev/null 2>&1 || die "Docker Compose is not available with a temporary config; run 'docker login ghcr.io' yourself, then re-run without GH_TOKEN"
fi
}

# ── 2. Source (installer + compose overlays only; images are prebuilt) ────
prepare_source() {
if [[ -n "$BUNDLE" ]]; then bundle_source; return 0; fi
if [[ ! -d "$DIR/.git" && -f "$DIR/$SOURCE_MARK" ]]; then
  # Installed from a bundle without git: repair with the installed release.
  (cd "$DIR" && sha256_check "$SOURCE_MARK") >> "$LOG_FILE" 2>&1 || die "Files in $DIR changed since the release was applied; preserve them before retrying."
  log "keeping the release installed from a bundle; to update, run install.sh from a newer bundle"
  return 0
fi
git_auth=()
[[ -n "${GH_TOKEN:-}" ]] && git_auth=(-c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')")
if [[ -d "$DIR/.git" ]]; then
  log "updating $DIR to $REF"
  if ! git ${git_auth[@]+"${git_auth[@]}"} -C "$DIR" fetch -q origin "$REF" >> "$LOG_FILE" 2>&1; then
    [[ -f "$DIR/$SOURCE_MARK" ]] || die "Could not download the update. Check your internet connection and repository address."
    (cd "$DIR" && sha256_check "$SOURCE_MARK") >> "$LOG_FILE" 2>&1 || die "Files in $DIR changed since the last release was applied; preserve them before retrying."
    log "could not download a newer release; keeping the release installed from a bundle"
    return 0
  fi
  if [[ -f "$DIR/$SOURCE_MARK" ]]; then
    # A bundle release was applied over this clone. Move the clone to the
    # downloaded release only when it contains that release and none of the
    # bundle's files were edited since.
    (cd "$DIR" && sha256_check "$SOURCE_MARK") >> "$LOG_FILE" 2>&1 || die "Files in $DIR changed since the last release was applied; preserve them before retrying."
    git -C "$DIR" merge-base --is-ancestor "$(sed -n 's/^SOURCE_COMMIT=//p' "$DIR/$SOURCE_RELEASE")" FETCH_HEAD >> "$LOG_FILE" 2>&1 || \
      die "The downloaded version is older than the release installed from a bundle; use a newer bundle or branch."
    # Only the verified bundle files are BawtHub's now; the clone's index still
    # lists the release before the bundle. The reset must not overwrite or
    # delete anything else, so refuse new paths that already exist and paths
    # only that stale index lists that are present again.
    local owned="$TEMP_DIR/owned-files" incoming="$TEMP_DIR/incoming-files" stale="$TEMP_DIR/stale-files" path
    sed -E 's/^[0-9a-f]{64}  \*?//' "$DIR/$SOURCE_MARK" | sort -u > "$owned"
    git -C "$DIR" ls-tree -r --name-only FETCH_HEAD | sort > "$incoming" || die "Could not read the downloaded release."
    release_collisions "$owned" "$incoming"
    git -C "$DIR" ls-files | sort -u | comm -23 - "$owned" | while IFS= read -r path; do
      [[ ! -e "$DIR/$path" && ! -L "$DIR/$path" ]] || echo "$path"
    done > "$stale"
    if [[ -s "$stale" ]]; then
      head -n 5 "$stale" | sed 's/^/  /' >&2
      die "Files in $DIR (listed above) were not installed by the current release and the update would replace or delete them. Move them elsewhere, then retry."
    fi
    git -C "$DIR" reset -q --hard FETCH_HEAD >> "$LOG_FILE" 2>&1 || die "Could not move $DIR to the downloaded release."
    # Bundle files the downloaded release no longer ships (the reset only
    # reconciles files the clone tracked).
    comm -23 "$owned" "$incoming" | while IFS= read -r path; do
      case "/$path/" in */../*) continue ;; esac
      # The downloaded release may ship a folder where the bundle had a file.
      [[ -d "$DIR/$path" && ! -L "$DIR/$path" ]] && continue
      rm -f -- "$DIR/$path"
    done
    rm -f -- "$DIR/$SOURCE_MARK" "$DIR/$SOURCE_RELEASE"
    return 0
  fi
  git -C "$DIR" merge -q --ff-only FETCH_HEAD >> "$LOG_FILE" 2>&1 || die "$DIR has local changes or commits; preserve them before retrying."
elif [[ -e "$DIR" ]]; then
  die "$DIR exists but is not a BawtHub clone; set BAWTHUB_DIR to another path"
else
  log "cloning $REPO ($REF) into $DIR"
  git ${git_auth[@]+"${git_auth[@]}"} clone -q --branch "$REF" "$REPO" "$DIR" >> "$LOG_FILE" 2>&1 || die "Could not download BawtHub. Check your internet connection and repository address."
fi
}

# ── 2b. Release bundle (no GitHub or registry login) ──────────────────────
# Layout: install.sh, release.txt (SOURCE_COMMIT=<40 hex>), source.tar (git
# archive of that commit), published-pins (every pin the release history
# published, for update planning), SHA256SUMS over those four, and registry/
# (registry storage with the release's images; content is checked by digest
# when Docker pulls it). Built by deploy/make-release-bundle.sh.
SOURCE_MARK=.bawthub-source       # sha256 and path of every file the snapshot wrote
SOURCE_RELEASE=.bawthub-release   # SOURCE_COMMIT of the applied snapshot

sha256_check() { # $1 = "hash  path" list, relative to the current directory
  if command -v sha256sum >/dev/null 2>&1; then sha256sum --status -c "$1"; else shasum -a 256 --status -c "$1"; fi
}
sha256_list() { # paths on stdin (one per line) → "hash  path" lines
  local path
  while IFS= read -r path; do
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$path"; else shasum -a 256 -- "$path"; fi
  done
}

# Refuse, before anything changes, a release that would write over a file the
# installed release does not own: a path it ships for the first time already
# exists in $DIR, or one of its parent directories is a file or symlink there.
# $1 = files the installed release owns, $2 = files the incoming release ships
# (both sorted, relative to $DIR).
release_collisions() {
  local path parent found="$TEMP_DIR/collisions"
  : > "$found"
  comm -13 "$1" "$2" | while IFS= read -r path; do
    if [[ -e "$DIR/$path" || -L "$DIR/$path" ]]; then echo "$path" >> "$found"; continue; fi
    parent="$path"
    while [[ "$parent" == */* ]]; do
      parent="${parent%/*}"
      [[ -L "$DIR/$parent" || ( -e "$DIR/$parent" && ! -d "$DIR/$parent" ) ]] || continue
      # A release file this release drops is removed before unpacking.
      grep -qxF "$parent" "$1" && ! grep -qxF "$parent" "$2" && continue
      echo "$parent" >> "$found"; break
    done
  done
  [[ -s "$found" ]] || return 0
  sort -u "$found" | head -n 5 | sed 's/^/  /' >&2
  die "This release adds files that already exist in $DIR (listed above) and were not installed by BawtHub. Move them elsewhere, then retry."
}

bundle_verify() {
  local f
  [[ "$BUNDLE" == /* ]] || BUNDLE="$PWD/$BUNDLE"
  for f in install.sh release.txt source.tar published-pins SHA256SUMS; do
    [[ -f "$BUNDLE/$f" ]] || die "The release bundle at $BUNDLE is incomplete ($f is missing). Copy the whole folder again."
    [[ "$f" == SHA256SUMS ]] || grep -qE "^[0-9a-f]{64}  \\*?$f\$" "$BUNDLE/SHA256SUMS" || die "The release bundle's checksum list does not cover $f."
  done
  (( SOURCE_ONLY )) || [[ -d "$BUNDLE/registry/docker/registry/v2" ]] || die "The release bundle has no images. Copy the whole folder again."
  (cd "$BUNDLE" && sha256_check SHA256SUMS) >> "$LOG_FILE" 2>&1 || die "The release bundle is damaged (checksums do not match). Copy it again."
  BUNDLE_COMMIT="$(sed -n 's/^SOURCE_COMMIT=//p' "$BUNDLE/release.txt" | tail -n 1)"
  [[ "$BUNDLE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "The release bundle does not name its release."
  if (( SOURCE_ONLY )); then
    log "Using packaged CLI release ${BUNDLE_COMMIT:0:12} (images are pulled by digest)"
  else
    log "Using release bundle ${BUNDLE_COMMIT:0:12} from $BUNDLE"
  fi
}

bundle_source() {
  local entry path old_list="$TEMP_DIR/old-files" new_list="$TEMP_DIR/new-files"
  tar -tf "$BUNDLE/source.tar" > "$TEMP_DIR/tar-list" 2>> "$LOG_FILE" || die "The release bundle's source snapshot cannot be read."
  while IFS= read -r entry; do
    case "/$entry/" in //*|*/../*) die "The release bundle's source snapshot has an unsafe path: $entry" ;; esac
  done < "$TEMP_DIR/tar-list"
  grep -v '/$' "$TEMP_DIR/tar-list" | sed 's#^\./##' | grep -vx 'pax_global_header' | sort > "$new_list" || true
  for entry in deploy/install.sh deploy/bootstrap.sh deploy/tenant.env.example; do
    grep -qxF "$entry" "$new_list" || die "The release bundle's source snapshot is not a BawtHub release ($entry is missing)."
  done
  if [[ -f "$DIR/$SOURCE_MARK" ]]; then
    (cd "$DIR" && sha256_check "$SOURCE_MARK") >> "$LOG_FILE" 2>&1 || die "Files in $DIR changed since the last release was applied; preserve them before retrying."
    sed -E 's/^[0-9a-f]{64}  \*?//' "$DIR/$SOURCE_MARK" | sort > "$old_list"
  elif [[ -d "$DIR/.git" ]]; then
    git -C "$DIR" diff --quiet HEAD -- >> "$LOG_FILE" 2>&1 || die "$DIR has local changes; preserve them before retrying."
    git -C "$DIR" ls-files | sort > "$old_list"
  elif [[ -e "$DIR" ]]; then
    die "$DIR exists but is not a BawtHub installation; set BAWTHUB_DIR to another path"
  else
    mkdir -p "$DIR"; : > "$old_list"
  fi
  release_collisions "$old_list" "$new_list"
  log "installing release ${BUNDLE_COMMIT:0:12} into $DIR from the bundle"
  # Files the previous release had and this one dropped. Only release files
  # are listed, so settings, data and other untracked files are never touched.
  comm -23 "$old_list" "$new_list" | while IFS= read -r path; do
    case "/$path/" in */../*) continue ;; esac
    rm -f -- "$DIR/$path"
  done
  tar -xf "$BUNDLE/source.tar" -C "$DIR" >> "$LOG_FILE" 2>&1 || die "Could not unpack the release into $DIR."
  (cd "$DIR" && sha256_list < "$new_list" > "$SOURCE_MARK.tmp" && mv -f "$SOURCE_MARK.tmp" "$SOURCE_MARK") || die "Could not record the installed release files."
  printf 'SOURCE_COMMIT=%s\n' "$BUNDLE_COMMIT" > "$DIR/$SOURCE_RELEASE"
}

start_bundle_registry() {
  local port ready logs tried=" "
  log "starting the bundle's local image source"
  docker image inspect "$BUNDLE_REGISTRY_IMAGE" >/dev/null 2>&1 || docker pull -q "$BUNDLE_REGISTRY_IMAGE" >> "$LOG_FILE" 2>&1 || \
    die "Could not download the small image server the bundle uses (Docker Hub). Check your internet connection."
  REGISTRY_CONTAINER="bawthub-bundle-registry-$$"
  # Read-only, removed when the installer exits, and listening only on the
  # loopback of the machine that runs the Docker daemon: the host network plus
  # a 127.0.0.1 listen address. The daemon pulls from that loopback. A port
  # published to the host (-p 127.0.0.1:...) is not enough: Docker Desktop's
  # daemon runs in its own VM and cannot reach the Mac's loopback. A taken
  # port makes the registry exit, so another (never a repeated) port is tried.
  # Its own log driver keeps the bind message readable when the daemon's
  # default (e.g. "none") would hide it; the daemon and other containers keep theirs.
  for _ in 1 2 3 4 5; do
    port=$(( 49152 + RANDOM % 16000 ))
    while [[ "$tried" == *" $port "* ]]; do port=$(( 49152 + RANDOM % 16000 )); done
    tried+="$port "
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$REGISTRY_CONTAINER" --network host --log-driver local \
      -e REGISTRY_HTTP_ADDR="127.0.0.1:$port" \
      -v "$BUNDLE/registry:/var/lib/registry:ro" \
      -e REGISTRY_STORAGE_MAINTENANCE_READONLY='{"enabled":true}' \
      -e REGISTRY_STORAGE_MAINTENANCE_UPLOADPURGING='{"enabled":false}' \
      "$BUNDLE_REGISTRY_IMAGE" >> "$LOG_FILE" 2>&1 || die "Could not start the bundle's local image source."
    ready=0
    for _ in $(seq 1 30); do
      [[ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_CONTAINER" 2>/dev/null)" == true ]] || break
      # On the host network another service may already answer on this port,
      # so only this registry's own bind message proves the port is ours; it
      # is logged after a successful listen (a taken port logs "address
      # already in use" and exits). The HTTP check is then made from inside,
      # since Docker Desktop's listener is not reachable from this shell:
      # bounded, and never through a proxy Docker may have injected.
      logs="$(docker logs "$REGISTRY_CONTAINER" 2>&1)" || logs=""
      if [[ "$logs" == *"msg=\"listening on 127.0.0.1:$port\""* ]] &&
        docker exec "$REGISTRY_CONTAINER" wget -q -T 2 -Y off -O /dev/null "http://127.0.0.1:$port/v2/" >> "$LOG_FILE" 2>&1; then
        ready=1; break
      fi
      sleep 1
    done
    (( ready )) && break
  done
  (( ready )) || die "The bundle's local image source did not start."
  BAWTHUB_IMAGE_MIRROR="127.0.0.1:$port"; export BAWTHUB_IMAGE_MIRROR
}

# ── 3. Manifest (created once, never overwritten) ─────────────────────────
prepare_manifest() {
if [[ ! -f "$env_file" ]]; then
  # The local database password is not written here: bootstrap generates it on
  # the first `up` and keeps it in deploy/.postgres-password (0600).
  local project="${BAWTHUB_CLI_INITIAL_PROJECT:-}" port="${BAWTHUB_CLI_INITIAL_PORT:-}" tmp="$env_file.install-$$"
  if [[ -n "${BAWTHUB_PACKAGED_RELEASE:-}" && -n "$project" ]]; then
    [[ "$project" =~ ^bawthub-cli-[0-9a-f]{12}$ && "$port" =~ ^30(0[0-9]|1[0-9]|20)$ ]] \
      || die 'Invalid initial CLI project or port.'
    ( umask 077; awk -v project="$project" -v port="$port" '
        /^TENANT_NAME=/ || /^FRONTEND_PORT=/ {next}
        {print}
        END {print "TENANT_NAME=" project; print "FRONTEND_PORT=" port}
      ' "$DIR/deploy/tenant.env.example" > "$tmp" && mv "$tmp" "$env_file" ) \
        || die "could not create $env_file"
  else
    ( umask 077; cp "$DIR/deploy/tenant.env.example" "$tmp" && mv "$tmp" "$env_file" ) \
      || die "could not create $env_file"
  fi
  log "created $env_file from tenant.env.example"
  first_install_parts
else
  log "keeping existing $env_file"
  # Share bootstrap's existing-tenant decision; fail before offering or staging pins.
  TENANT_ENV="$env_file" "$DIR/deploy/bootstrap.sh" check-access </dev/null \
    || die 'Resolve the access setting above before updating. No image pins changed.'
  plan_update
fi
}

# ── 3b. Release update ────────────────────────────────────────────────────
# A pin is release-managed when it equals a value this repository has ever
# published for that key in tenant.env.example. Only those move to the new
# release; any other value is a custom pin and is kept. A commented-out or
# empty pin is a turned-off component and stays off (an absent microphone pin
# also means off); other absent pins are required and get added. The
# manifest is never evaluated: a pin written any other way than a plain
# KEY=value line (export, +=, a reference) cannot be planned safely, so no
# update is offered until it is rewritten.
pin_name() { local n="${1%_IMAGE_REF}"; n="${n//_/ }"; printf '%s' "$n" | tr '[:upper:]' '[:lower:]'; }
published_pin() { grep -qxF "$1=$2" "$TEMP_DIR/published-pins"; }
unusual_pin() {
  grep -vE '^[[:space:]]*#' "$env_file" | grep -E "(^|[^A-Za-z0-9_])$1([^A-Za-z0-9_]|$)" | grep -qvE "^$1="
}
plan_update() {
  local key want cur off
  local unusual=()
  UPDATE_PLAN="$TEMP_DIR/update-pins"; : > "$UPDATE_PLAN"
  UPDATE_NAMES=(); CUSTOM_PINS=(); OFF_PINS=(); REFRESH_OFF=()
  if [[ "$(manifest_value IMAGE_SOURCE)" == local ]]; then
    log "this installation uses locally built images; image pins are left as they are"
    return 0
  fi
  { git -C "$DIR" log --format= -p -- deploy/tenant.env.example 2>> "$LOG_FILE" || true; cat "$DIR/deploy/tenant.env.example"; } \
    | sed -n -E 's/^[-+ ]?#?([A-Z][A-Z0-9_]*_IMAGE_REF=[^[:space:]]+).*$/\1/p' > "$TEMP_DIR/published-pins"
  # A bundle install has no (or older) git history; the bundle lists them all.
  [[ -z "$BUNDLE" ]] || cat "$BUNDLE/published-pins" >> "$TEMP_DIR/published-pins"
  while IFS='=' read -r key want; do
    if unusual_pin "$key"; then unusual+=("$key"); continue; fi
    cur="$(manifest_value "$key")"
    if [[ -z "$cur" ]]; then
      off=0
      grep -qE "^#[[:space:]]*$key=|^$key=" "$env_file" && off=1
      [[ "$key" != CPU_STT_IMAGE_REF ]] || off=1
      if (( off )); then
        OFF_PINS+=("$(pin_name "$key")")
        cur="$(sed -n -E "s/^#[[:space:]]*$key=([^[:space:]]+).*/\1/p" "$env_file" | tail -n 1)"
        if [[ -n "$cur" && "$cur" != "$want" ]] && published_pin "$key" "$cur"; then REFRESH_OFF+=("$key"); fi
        continue
      fi
      printf '%s - %s\n' "$key" "$want" >> "$UPDATE_PLAN"
    elif [[ "$cur" == "$want" ]]; then
      continue
    elif published_pin "$key" "$cur"; then
      printf '%s %s %s\n' "$key" "$cur" "$want" >> "$UPDATE_PLAN"
    else
      CUSTOM_PINS+=("$(pin_name "$key")")
      continue
    fi
    UPDATE_NAMES+=("$(pin_name "$key")")
  done < <(grep -E '^[A-Z][A-Z0-9_]*_IMAGE_REF=' "$DIR/deploy/tenant.env.example")
  if (( ${#unusual[@]} )); then
    : > "$UPDATE_PLAN"; UPDATE_NAMES=(); REFRESH_OFF=()
    log "cannot update automatically: $env_file sets ${unusual[*]} other than as a plain KEY=value line"
    log "rewrite each as KEY=value (no export), then run the installer again; your current images are kept"
    [[ "$ACTION" != update ]] || die "No update was applied. Rewrite ${unusual[*]} in $env_file as plain KEY=value lines, then run the update again."
    return 0
  fi
  (( ${#CUSTOM_PINS[@]} == 0 )) || log "keeping your custom images: ${CUSTOM_PINS[*]}"
  (( ${#OFF_PINS[@]} == 0 )) || log "keeping turned-off parts off: ${OFF_PINS[*]}"
  if [[ ! -s "$UPDATE_PLAN" ]]; then log "Service image versions are unchanged; checking the installation"; fi
}

choose_update() {
  [[ -s "$UPDATE_PLAN" ]] || return 1
  [[ "$ACTION" != update ]] || return 0
  if (( INTERACTIVE )); then
    printf '\nA newer BawtHub release is available.\n  Updates: %s\n  Your data, settings and custom images are kept.\n' "${UPDATE_NAMES[*]}" >&3
    (( ${#OFF_PINS[@]} == 0 )) || printf '  Stays off: %s\n' "${OFF_PINS[*]}" >&3
    ask 'Update now? [Y/n]: '
    case "${REPLY:-y}" in y|Y|yes|Yes) return 0 ;; n|N|no|No) log "keeping the current version"; return 1 ;; *) die "Answer y or n." ;; esac
  fi
  log "a newer release is available (${UPDATE_NAMES[*]}); keeping the current version"
  log "to update, run this installer with: update"
  return 1
}

apply_update() {
  local rc=0
  log "Updating BawtHub: ${UPDATE_NAMES[*]}"
  bootstrap_call update --pins "$UPDATE_PLAN" || rc=$?
  case "$rc" in
    0) ;;
    3)
      log "The update did not start, so BawtHub went back to the version you had. Your data is kept."
      log "Database changes the new version made stay in place. Pin backup: $(dirname "$env_file")/.update/"
      finish
      printf '\nUpdate failed; your previous version is running. Details: %s\n' "$LOG_FILE" >&2
      exit 3 ;;
    4) die "The update failed and the previous version did not come back healthy. Your previous settings are saved in $(dirname "$env_file")/.update/." ;;
    1) die "The update was refused before anything changed. The reason is in the details below." ;;
    *) die "The update stopped unexpectedly. Check the details below before running it again." ;;
  esac
  refresh_off_pins
  log "BawtHub updated: ${UPDATE_NAMES[*]}"
}

# Keep a turned-off part's saved pin current, so turning it on uses this release.
refresh_off_pins() {
  local key want tmp="$env_file.install-$$"
  for key in ${REFRESH_OFF[@]+"${REFRESH_OFF[@]}"}; do
    want="$(sed -n "s/^$key=//p" "$DIR/deploy/tenant.env.example" | tail -n 1)"
    (umask 077; awk -v key="$key" -v want="$want" '
      $0 ~ "^#[[:space:]]*" key "=" {print "#" key "=" want; next}
      {print}
    ' "$env_file" > "$tmp")
    mv -f "$tmp" "$env_file"
  done
}

# ── 4. Install / upgrade ──────────────────────────────────────────────────
run_bootstrap() {
  bootstrap_call "$@" || die "BawtHub could not complete '$*'. Check Docker and the last error below."
}

bootstrap_call() {
  rm -f "$TEMP_DIR/ready" "$TEMP_DIR/code-file" "$TEMP_DIR/access" "$TEMP_DIR/sessions"
  local elapsed="$SECONDS" line
  # Let Compose emit durable progress lines even though the installer captures
  # its output. Only known progress formats, not arbitrary subprocess output,
  # are echoed to the terminal; detailed diagnostics stay in the private log.
  local resource='^[[:space:]]*(Image |Container |Network |Volume )?([a-zA-Z0-9][a-zA-Z0-9_./:@-]*)[[:space:]]+(Pulling|Pulled|Skipped|Creating|Created|Starting|Started|Running|Waiting|Healthy|Unhealthy|Recreating|Recreated|Downloading|Downloaded|Extracting|Interrupted|Error)([[:space:]]|$)'
  local layer='^[[:space:]]*([0-9a-f]{8,64})[[:space:]]+(Pulling fs layer|Waiting|Downloading|Verifying Checksum|Download complete|Extracting|Pull complete)([[:space:]]|$)'
  local bytes='([0-9.]+[kKMGT]?i?B[[:space:]]*/[[:space:]]*[0-9.]+[kKMGT]?i?B)'
  if COMPOSE_ANSI=never COMPOSE_PROGRESS=plain "$DIR/deploy/bootstrap.sh" "$@" </dev/null 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'bootstrap: @step '*) printf '  [%ss] %s\n' "$((SECONDS - elapsed))" "${line#bootstrap: @step }" >&2; detail "$line" ;;
      'bootstrap: @access '*) printf '%s\n' "${line#bootstrap: @access }" > "$TEMP_DIR/access" ;;
      'bootstrap: @sessions '*) printf '%s\n' "${line#bootstrap: @sessions }" > "$TEMP_DIR/sessions" ;;
      'bootstrap: @ready '*) printf '%s\n' "${line#bootstrap: @ready }" > "$TEMP_DIR/ready" ;;
      'bootstrap: @setup-code-file '*) printf '%s\n' "${line#bootstrap: @setup-code-file }" > "$TEMP_DIR/code-file" ;;
      'bootstrap: sign-in: '*'enter setup code '*)
        # Legacy frontend fallback may contain a code. Terminal only, never log.
        if (( TTY_AVAILABLE )); then printf '%s\n' "$line" >&3
        else printf 'Owner setup uses an older frontend; run bootstrap up in a terminal to see its one-time code.\n' >&2; fi ;;
      *)
        detail "$line"
        if (( VERBOSE )) && [[ "$line" =~ $layer ]]; then
          local id="${BASH_REMATCH[1]}" state="${BASH_REMATCH[2]}" transfer=""
          if [[ "$line" =~ $bytes ]]; then transfer=" ${BASH_REMATCH[1]}"; fi
          printf '    %s: %s%s\n' "$id" "$state" "$transfer" >&2
        elif [[ "$line" =~ $resource ]]; then
          # Hex-only tokens are layer IDs, not resource updates.
          local name="${BASH_REMATCH[2]}" state="${BASH_REMATCH[3]}"
          if [[ ! "$name" =~ ^[0-9a-f]{8,64}$ ]]; then
            printf '    %s: %s\n' "$name" "$state" >&2
          fi
        fi ;;
    esac
  done; then
    return 0
  else
    return $?
  fi
}

project_resources() {
  local kind="$1" ids id
  case "$kind" in
    container) ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ;;
    volume) ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ;;
    network) ids="$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT")" ;;
  esac
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    case "$kind" in
      container) docker rm -f "$id" >> "$LOG_FILE" 2>&1 ;;
      volume) docker volume rm "$id" >> "$LOG_FILE" 2>&1 ;;
      network) docker network rm "$id" >> "$LOG_FILE" 2>&1 ;;
    esac
  done <<< "$ids"
}

check_checkout_exclusive() {
  local inventory project configs workdir file tenant assignment
  local tenant_pattern="^([a-z0-9][a-z0-9_-]*|'[a-z0-9][a-z0-9_-]*'|\"[a-z0-9][a-z0-9_-]*\")([[:space:]]+#.*|[[:space:]]*)$"
  inventory="$(docker ps -a --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.config_files"}}|{{.Label "com.docker.compose.project.working_dir"}}')"
  while IFS='|' read -r project configs workdir; do
    [[ -n "$project" && "$project" != "$PROJECT" ]] || continue
    if [[ "$configs" == *"$target/"* || "$workdir" == "$target" || "$workdir" == "$target/"* ]]; then
      die "Another tenant uses this installation. Choose keep-data uninstall and remove only your tenant's files manually."
    fi
  done <<< "$inventory"
  while IFS= read -r file; do
    case "$file" in
      "$MANIFEST"|"$MANIFEST.before-settings"|"$MANIFEST.install-"*|"$target/deploy/tenant.env.example") continue ;;
    esac
    assignment="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?TENANT_NAME=(.*)$/\2/p' "$file" | tail -n 1)"
    assignment="${assignment%$'\r'}"
    [[ "$assignment" =~ $tenant_pattern ]] || die "Another tenant manifest cannot be identified safely. Choose keep-data uninstall; no files erased."
    tenant="${BASH_REMATCH[1]}"; tenant="${tenant#\"}"; tenant="${tenant%\"}"
    tenant="${tenant#\'}"; tenant="${tenant%\'}"
    [[ "$tenant" == "$TENANT_NAME" ]] || die "Another tenant manifest exists in this installation. Choose keep-data uninstall; no files erased."
  done < <(find "$target/deploy" -type f -name '*env*')
}

uninstall() {
  local paths key value target secret_target deploy_target refs ref
  local TENANT_NAME="" PROJECT="" SECRETS_DIR="" MANIFEST="" DEPLOY_DIR=""
  [[ ( -d "$DIR/.git" || -f "$DIR/$SOURCE_MARK" ) && -f "$DIR/deploy/bootstrap.sh" ]] || die "No BawtHub installation found at $DIR. Set BAWTHUB_DIR to its location."
  paths="$("$DIR/deploy/bootstrap.sh" paths </dev/null 2>> "$LOG_FILE")" || die "Cannot read this installation's paths. Repair the installer before uninstalling."
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_NAME) TENANT_NAME="$value" ;; PROJECT) PROJECT="$value" ;;
      SECRETS_DIR) SECRETS_DIR="$value" ;; MANIFEST) MANIFEST="$value" ;;
      DEPLOY_DIR) DEPLOY_DIR="$value" ;;
    esac
  done <<< "$paths"
  [[ "$TENANT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ && "$PROJECT" == "$TENANT_NAME" ]] || die "The tenant/project identity is missing or inconsistent; nothing removed."
  if (( INTERACTIVE )); then
    printf '\nUninstall %s from %s\n  1) Remove containers, keep data (recommended)\n  2) Completely erase this tenant\n  3) Cancel\n' "$TENANT_NAME" "$DIR" >&3
    ask 'Choice [1]: '
    case "${REPLY:-1}" in 1) WIPE=0 ;; 2) WIPE=1 ;; 3) return 0 ;; *) die "Choose 1, 2 or 3." ;; esac
  fi
  if (( ! WIPE )); then
    run_bootstrap down
    log "BawtHub stopped. Your database, files and settings are kept. Run Install/repair to start it again."
    return 0
  fi
  [[ ! -L "$DIR" && "$DIR" == /* ]] || die "Full removal needs an absolute installation path, not a symlink."
  target="$(cd "$DIR" && pwd -P)"
  deploy_target="$(cd "$DEPLOY_DIR" && pwd -P)"
  [[ "$target" != / && "$target" != "$HOME" && "$target" != "$HOME/.config" && "$target" != "$HOME/.config/bawthub" && "$deploy_target" == "$target/deploy" ]] || die "Unsafe installation path; nothing removed."
  [[ "$MANIFEST" == "$target/deploy/"* && -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "Full removal only supports a manifest inside this installation's deploy directory."
  [[ "$SECRETS_DIR" == /* && ! -L "$SECRETS_DIR" ]] || die "The secrets directory must be an absolute path, not a symlink; nothing removed."
  if [[ -d "$SECRETS_DIR" ]]; then secret_target="$(cd "$SECRETS_DIR" && pwd -P)"
  else
    # A partially completed wipe may already have removed this directory.
    secret_target="$(cd "$(dirname "$SECRETS_DIR")" && pwd -P)/$(basename "$SECRETS_DIR")"
  fi
  case "$secret_target" in
    "$target"/*|"$HOME/.config/bawthub/$TENANT_NAME") ;;
    *) die "The custom secrets directory may be shared. Remove it manually after a keep-data uninstall; nothing erased." ;;
  esac
  check_checkout_exclusive
  refs="$(env_file="$MANIFEST" manifest_images)"
  printf '\nErase tenant: %s\nProject containers, volumes and networks: %s\nInstallation: %s\nSecrets: %s\nPinned images (only when not in use):\n%s\nExternal databases are NOT erased. This cannot be undone.\n' \
    "$TENANT_NAME" "$PROJECT" "$target" "$secret_target" "$refs" >&2
  if (( INTERACTIVE )); then ask "Type $TENANT_NAME to erase this tenant: "; CONFIRM="$REPLY"; fi
  [[ "$CONFIRM" == "$TENANT_NAME" ]] || die "Confirmation did not match. No data was removed."
  # Label inventory also covers houses and works after a partially finished
  # wipe, when bootstrap's normal secret/database preconditions no longer hold.
  project_resources container
  project_resources volume
  project_resources network
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    docker image rm "$ref" >> "$LOG_FILE" 2>&1 || detail "Image retained (shared, in use, or already absent): $ref"
  done <<< "$refs"
  # Only positively scoped paths above are eligible. Never prune globally.
  case "$secret_target" in "$target"/*) ;; *) rm -rf -- "$secret_target" ;; esac
  rm -rf -- "$target"
  log "Removed tenant $TENANT_NAME. Other tenants and shared/in-use images were left alone."
}

manifest_images() {
  local key ref
  while IFS='=' read -r key ref; do
    case "$key" in
      *_IMAGE_REF|EMBED_IMAGE)
        ref="$(manifest_value "$key")"
        [[ -n "$ref" && "$ref" != -* && "$ref" != *[[:space:]]* ]] || continue
        printf '%s\n' "$ref"
        ;;
    esac
  done < "$env_file"
}

# Parse the whole program before running it: prompts never consume curl|bash.
lifecycle_menu() {
  local action
  printf '\n  1) Start\n  2) Stop (keep all data)\n  3) Restart\n  4) Status\n  5) Recent logs\n  6) Cancel\n\n' >&3
  ask 'Choose [4]: '
  case "${REPLY:-4}" in
    1) action=start ;; 2) action=stop ;; 3) action=restart ;; 4) action=status ;;
    5) bash "$1" --dir "$DIR" logs --tail 100; return ;;
    6|q|Q) return 0 ;; *) die 'Choose 1 through 6.' ;;
  esac
  bash "$1" --dir "$DIR" "$action"
}

main() {
  local explicit=0 option value self lifecycle="$DIR/deploy/bh"
  TTY_AVAILABLE=0
  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; return 0; fi
  if (( $# )); then ACTION="$1"; explicit=1; shift; fi
  case "$ACTION" in install|update|configure|uninstall) ;; *) usage >&2; die "Unknown action: $ACTION" ;; esac
  while (( $# )); do
    option="$1"; shift
    case "$option" in
      --wipe) WIPE=1; continue ;;
      --core-only) CORE_ONLY=1; continue ;;
      --verbose) VERBOSE=1; continue ;;
      --confirm|--voice|--microphone|--agent-tools|--port|--lan-address|--access|--bot-pack|--bundle)
        (( $# )) || die "$option needs a value."
        value="$1"; shift ;;
      *) die "Unknown option: $option (see --help)." ;;
    esac
    case "$option" in
      --confirm) CONFIRM="$value" ;;
      --bot-pack) BOT_PACK="$value" ;;
      --bundle)
        [[ "$ACTION" == install || "$ACTION" == update ]] || die '--bundle requires install or update.'
        [[ -n "$value" && "$value" != --* ]] || die '--bundle needs a directory.'
        BUNDLE="$value" ;;
      --voice) SETTINGS+=("VOICE=$value") ;;
      --microphone) SETTINGS+=("MICROPHONE=$value") ;;
      --agent-tools)
        case "$value" in on) value=1 ;; off) value=0 ;; esac
        SETTINGS+=("AGENT_TOOLS=$value") ;;
      --port) SETTINGS+=("FRONTEND_PORT=$value") ;;
      --lan-address) SETTINGS+=("FRONTEND_HOST=$value") ;;
      --access) SETTINGS+=("ACCESS=$value") ;;
    esac
  done
  # Opening a controlling terminal works even with a piped launcher stdin.
  if { exec 3<>/dev/tty; } 2>/dev/null; then TTY_AVAILABLE=1; fi
  header
  if (( ! explicit && TTY_AVAILABLE )) && [[ "${BAWTHUB_NONINTERACTIVE:-0}" != 1 ]]; then
    INTERACTIVE=1
    option="Install"
    [[ ! -f "${TENANT_ENV:-${DIR%/}/deploy/tenant.env}" ]] || option="Update / repair"
    printf '  1) %s\n  2) Change settings\n  3) Uninstall\n  4) Quit\n' "$option" >&3
    [[ -f "$lifecycle" ]] || lifecycle="$HOME/.local/bin/bh"
    if [[ "$option" == 'Update / repair' && -f "$lifecycle" ]]; then
      printf '  5) Start, stop, restart, status or logs\n' >&3
    else
      lifecycle=""
    fi
    printf '\n' >&3
    ask 'Choose [1]: '
    case "${REPLY:-1}" in
      1) ACTION=install ;; 2) ACTION=configure ;; 3) ACTION=uninstall ;; 4|q|Q) return 0 ;;
      5) [[ -n "$lifecycle" ]] || die 'Lifecycle controls require an installed tenant and the bh CLI.'
         lifecycle_menu "$lifecycle"; return ;;
      *) die 'Choose a listed option.' ;;
    esac
  fi
  (( WIPE == 0 )) || [[ "$ACTION" == uninstall ]] || die "--wipe is only for uninstall."
  (( CORE_ONLY == 0 )) || [[ "$ACTION" == install ]] || die "--core-only is only for install."
  if [[ -n "$BOT_PACK" ]]; then
    [[ "$ACTION" == install || "$ACTION" == update ]] || die "--bot-pack is only for install or update."
    [[ -f "$BOT_PACK" && -r "$BOT_PACK" ]] || die "Cannot read the bot pack $BOT_PACK."
  fi
  (( ${#SETTINGS[@]} == 0 )) || [[ "$ACTION" == configure ]] || die "Setting options require configure."
  [[ "$DIR" == /* ]] || DIR="$PWD/$DIR"
  DIR="${DIR%/}"
  # A bundle's own install.sh sits beside its release files. Piped installs
  # (curl | bash) have no script file, so they never match.
  if [[ -z "$BUNDLE" && -f "${BASH_SOURCE[0]:-}" ]]; then
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    [[ "$self" == "${BAWTHUB_PACKAGED_RELEASE:-}" || ! -f "$self/release.txt" || ! -f "$self/source.tar" || ! -f "$self/SHA256SUMS" ]] || BUNDLE="$self"
  fi
  # A packaged CLI carries checked source and pins, but pulls images normally.
  # An explicit offline bundle still takes precedence over the packaged source.
  if [[ "$ACTION" == install || "$ACTION" == update ]]; then
    if [[ -z "$BUNDLE" && -n "${BAWTHUB_PACKAGED_RELEASE:-}" ]]; then
      if [[ "$ACTION" == update || ! -f "$DIR/$SOURCE_MARK" ]] ||
         # Refresh only the known affected CLI snapshots on a plain retry;
         # an install from a different release bundle keeps its own source.
         grep -qxE 'SOURCE_COMMIT=(b76a6cbd6124ae510ead28f2bb2d30a45e64b63d|25e47c623348bb1df631ccfc62a33493fbf52dfa)' \
           "$DIR/$SOURCE_RELEASE" 2>/dev/null; then
        BUNDLE="$BAWTHUB_PACKAGED_RELEASE"
        SOURCE_ONLY=1
      fi
    fi
    if [[ -n "${BAWTHUB_PACKAGED_RELEASE:-}" && ( -e "$DIR/.git" || -L "$DIR/.git" ) ]]; then
      die 'The packaged CLI does not install over a Git checkout. Select a separate install directory.'
    fi
  else
    BUNDLE=""
  fi
  log "Checking this computer..."
  preflight
  mkdir -p "$HOME/.local/state/bawthub"
  LOG_FILE="$HOME/.local/state/bawthub/install-$(date +%Y%m%d-%H%M%S)-$$.log"
  (umask 077; : > "$LOG_FILE")
  log "Live log: $LOG_FILE"
  TEMP_DIR="$(mktemp -d)"
  private_access
  env_file="${TENANT_ENV:-$DIR/deploy/tenant.env}"
  case "$ACTION" in
    install|update)
      UPDATE_PLAN=""; REFRESH_OFF=()
      [[ -z "$BUNDLE" ]] || bundle_verify
      prepare_source
      prepare_manifest
      [[ -z "$BUNDLE" ]] || (( SOURCE_ONLY )) || start_bundle_registry
      if choose_update; then
        apply_update
      else
        # Saved pins of turned-off parts change only on an explicit update.
        [[ "$ACTION" != update ]] || refresh_off_pins
        run_bootstrap up
      fi
      choose_presets
      finish ;;
    configure) configure ;;
    uninstall) uninstall ;;
  esac
}

manifest_value() {
  # Manifest values are read as data, never sourced/evaluated by the installer.
  local value
  value="$(sed -n "s/^$1=//p" "$env_file" | tail -n 1)"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

put_setting() {
  local key="$1" value="$2" tmp="$env_file.install-$$"
  # Keys and values have already passed the fixed option allowlist.
  (umask 077; awk -v key="$key" -v value="$value" '
    $0 ~ "^" key "=" {if (!found++) print key "=" value; next}
    {print}
    END {if (!found) print key "=" value}
  ' "$env_file" > "$tmp")
  mv -f "$tmp" "$env_file"
}

set_microphone() {
  local pin tmp="$env_file.install-$$"
  pin="$(manifest_value CPU_STT_IMAGE_REF)"
  [[ -n "$pin" ]] || pin="$(sed -n 's/^#CPU_STT_IMAGE_REF=//p' "$env_file" | tail -n 1)"
  [[ -n "$pin" ]] || pin="$(sed -n 's/^CPU_STT_IMAGE_REF=//p' "$DIR/deploy/tenant.env.example" | tail -n 1)"
  [[ -n "$pin" || "$1" == off ]] || die "This release has no microphone image. Restore $env_file.before-settings and use a release with CPU speech input."
  # Comment the pin out rather than discard it: re-enabling keeps custom pins.
  (umask 077; awk -v pin="$pin" -v enabled="$1" '
    /^#?CPU_STT_IMAGE_REF=/ {next}
    {print}
    END {if (pin != "") print (enabled == "on" ? "" : "#") "CPU_STT_IMAGE_REF=" pin}
  ' "$env_file" > "$tmp")
  mv -f "$tmp" "$env_file"
}

validate_setting() {
  case "$1" in
    VOICE) [[ "$2" == pocket || "$2" == off ]] ;;
    AGENT_TOOLS) [[ "$2" == 0 || "$2" == 1 ]] ;;
    FRONTEND_PORT) [[ "$2" =~ ^[0-9]{1,5}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )) ;;
    FRONTEND_HOST) [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ;;
    MICROPHONE) [[ "$2" == on || "$2" == off ]] ;;
    ACCESS) [[ "$2" == signin || "$2" == trusted-lan ]] ;;
    *) return 1 ;;
  esac
}

# BAWTHUB_AUTH_SESSIONS as bootstrap will see it; empty when unset. Fails when
# bootstrap can't be read or predates this report.
session_override() {
  local paths
  paths="$("$DIR/deploy/bootstrap.sh" paths </dev/null 2>> "$LOG_FILE")" || return 1
  grep -q '^AUTH_SESSIONS=' <<< "$paths" || return 1
  sed -n 's/^AUTH_SESSIONS=//p' <<< "$paths" | tail -n 1
}

# The sign-in mode in effect: the manifest's ACCESS, else the one bootstrap
# recorded beside the tenant secrets. Empty when neither says.
current_access() {
  local value paths secrets=""
  value="$(manifest_value ACCESS)"
  if [[ -z "$value" ]]; then
    paths="$("$DIR/deploy/bootstrap.sh" paths </dev/null 2>> "$LOG_FILE")" || paths=""
    secrets="$(sed -n 's/^SECRETS_DIR=//p' <<< "$paths" | tail -n 1)"
    [[ -z "$secrets" || ! -f "$secrets/.access" || -L "$secrets/.access" ]] || value="$(head -n 1 "$secrets/.access")"
  fi
  validate_setting ACCESS "$value" || value=""
  printf '%s' "$value"
}

configure() {
  local key current label value item origin
  [[ -f "$env_file" ]] || die "Install BawtHub first, then choose Change settings."
  if (( INTERACTIVE )); then
    for key in VOICE MICROPHONE AGENT_TOOLS FRONTEND_PORT FRONTEND_HOST ACCESS; do
      case "$key" in
        VOICE) current="$(manifest_value VOICE)"; current="${current:-pocket}"; label="Voice replies (pocket/off; existing external kept on Enter)" ;;
        MICROPHONE) current=off; [[ -z "$(manifest_value CPU_STT_IMAGE_REF)" ]] || current=on; label="Microphone input (on/off)" ;;
        AGENT_TOOLS) current="$(manifest_value AGENT_TOOLS)"; current="${current:-1}"; label="Agent browser and web tools (1/0)" ;;
        FRONTEND_PORT) current="$(manifest_value FRONTEND_PORT)"; current="${current:-3000}"; label="Web port" ;;
        FRONTEND_HOST) current="$(manifest_value FRONTEND_HOST)"; current="${current:-localhost}"; label="LAN address (hostname or IPv4; no http:// or port)" ;;
        ACCESS)
          current="$(current_access)"; current="${current:-signin}"
          printf '\n  Sign-in: signin = everyone signs in (recommended);\n  trusted-lan = no sign-in, anyone who can reach this computer picks a user.\n' >&3
          label="Sign-in mode (signin/trusted-lan)" ;;
      esac
      while :; do
        ask "$label [$current]: "
        [[ -n "$REPLY" ]] || break
        if [[ "$key" == ACCESS && "$REPLY" == trusted-lan && "$current" != trusted-lan ]]; then
          ask "Turn off sign-in for everyone who can reach this computer? [y/N]: "
          [[ "$REPLY" == y || "$REPLY" == Y ]] || break
          REPLY=trusted-lan
        fi
        if validate_setting "$key" "$REPLY"; then SETTINGS+=("$key=$REPLY"); break; fi
        printf 'Please enter one of the supported values.\n' >&3
      done
    done
  fi
  (( ${#SETTINGS[@]} )) || { log "No settings changed."; return 0; }
  # Validate the entire request before changing any setting.
  for item in "${SETTINGS[@]}"; do
    validate_setting "${item%%=*}" "${item#*=}" || die "Unsupported setting: ${item%%=*}. See --help."
    case "${item%%=*}" in
      FRONTEND_PORT|FRONTEND_HOST)
        if [[ -n "$(manifest_value AGENT_ORIGIN)" || -n "$(manifest_value LLM_BAWT_PUBLIC_ORIGIN)" || -n "$(manifest_value BAWTHUB_AUTH_URL)" ]]; then
          die "This installation has custom sign-in origins. Update its port/address and matching origins together in $env_file; no settings changed."
        fi ;;
      ACCESS)
        # An explicit session override wins over the mode, so a mode that
        # contradicts it would be reported but not take effect. Ask bootstrap
        # for the value exactly as it will source it (comments, quoting and
        # inherited environment included).
        value="$(session_override)" || die "Cannot read this installation's sign-in settings; no settings changed."
        if [[ -n "$value" ]] && { [[ "${item#*=}" == signin && "$value" != on ]] || [[ "${item#*=}" == trusted-lan && "$value" != off ]]; }; then
          die "BAWTHUB_AUTH_SESSIONS=$value (in $env_file or the environment) overrides sign-in mode ${item#*=}. Remove or change it, then choose the mode again; no settings changed."
        fi ;;
    esac
  done
  cp -p "$env_file" "$env_file.before-settings"
  chmod 600 "$env_file.before-settings"
  for item in "${SETTINGS[@]}"; do
    key="${item%%=*}"; value="${item#*=}"
    current="$(manifest_value FRONTEND_HOST)"
    if [[ "$key" == FRONTEND_HOST && "$value" != "${current:-localhost}" && -z "$(manifest_value BAWTHUB_AUTH_PASSKEY_DOMAIN)" ]]; then
      # The passkey domain follows the sign-in host (unless one is configured).
      PASSKEY_HOST_CHANGED=1
    fi
    if [[ "$key" == MICROPHONE ]]; then
      set_microphone "$value"
      continue
    fi
    put_setting "$key" "$value"
  done
  # Explicit origin overrides must not leave sign-in pointing at the old port.
  origin="$(manifest_value AGENT_ORIGIN)"
  if [[ -n "$origin" || -n "$(manifest_value LLM_BAWT_PUBLIC_ORIGIN)" ]]; then
    log "Custom sign-in origins were kept. Check AGENT_ORIGIN and LLM_BAWT_PUBLIC_ORIGIN if changing address or port."
  fi
  run_bootstrap up
  finish
}

# What sign-in protection the running install has, from bootstrap's report of
# the frontend's effective session setting (an explicit override beats the mode).
sign_in_summary() {
  local access sessions host
  access="$(cat "$TEMP_DIR/access" 2>/dev/null || true)"
  sessions="$(cat "$TEMP_DIR/sessions" 2>/dev/null || true)"
  [[ -z "$access" ]] && return 0
  if [[ -z "$sessions" ]]; then
    # Older bootstrap: no effective report, so do not claim a posture.
    printf '  Sign-in mode: %s (check BAWTHUB_AUTH_SESSIONS in %s)\n' "$access" "$env_file"
    return 0
  fi
  if [[ "$access" == signin && "$sessions" != on ]] || [[ "$access" == trusted-lan && "$sessions" == on ]]; then
    printf '  Note: BAWTHUB_AUTH_SESSIONS=%s in %s overrides sign-in mode %s.\n' "$sessions" "$env_file" "$access"
  fi
  case "$sessions" in
    on)
      printf '  Sign-in: everyone signs in at %s\n' "$1"
      host="${1#*://}"; host="${host%%[:/]*}"
      if [[ "$1" == http://* && "$host" != localhost && "$host" != 127.0.0.1 ]]; then
        printf '  Passkeys need HTTPS at this address; sign in with your password.\n'
      fi
      if (( PASSKEY_HOST_CHANGED )); then
        printf '  Passkeys added at the old address no longer work; add one again.\n'
      fi ;;
    enroll)
      printf '  Sign-in: being set up (enroll). Passkeys can be added, but anyone\n  who can reach this computer can still use BawtHub as any user.\n' ;;
    off)
      printf '  Sign-in: off. Anyone who can reach this computer\n  can use BawtHub as any user.\n' ;;
    *)
      printf '  Sign-in: unrecognized BAWTHUB_AUTH_SESSIONS=%s; check %s.\n' "$sessions" "$env_file" ;;
  esac
}

# ── Bot presets (TASK-2516) ───────────────────────────────────────────────
# The app owns the catalog; the installer only shows it and records a choice.
# Bots are created in the browser setup once a model provider is connected.
preset_cli() {
  local tenant
  tenant="$(manifest_value TENANT_NAME)"; tenant="${tenant:-bawthub}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  # Only an import reads stdin; anything else must not consume a piped installer.
  if [[ "$1" == import ]]; then
    docker exec -i "$tenant-app" python -m llm_bawt.seeding.preset_cli "$@"
  else
    docker exec "$tenant-app" python -m llm_bawt.seeding.preset_cli "$@" </dev/null
  fi
}

choose_presets() {
  local listing saved words=()
  if [[ -n "$BOT_PACK" ]]; then
    preset_cli import - < "$BOT_PACK" >> "$LOG_FILE" 2>&1 \
      || die "Could not add the bots in $BOT_PACK. Use a pack exported by BawtHub, and check that this release has bot presets."
    log "Added the bots in $BOT_PACK to the choices in setup."
  fi
  (( INTERACTIVE && FIRST_INSTALL )) || return 0
  # An image from before presets has no CLI: setup still creates a first bot.
  listing="$(preset_cli list 2>> "$LOG_FILE")" || return 0
  printf '\n  Choose your bots. [x] marks the current choice.%s\n' "$listing" >&3
  while :; do
    ask "  Numbers to create (Enter keeps the [x] ones, 'none' for none): "
    read -r -a words <<< "${REPLY:-current}"
    (( ${#words[@]} )) || words=(current)
    if saved="$(preset_cli select "${words[@]}" 2>&1)"; then
      printf '  %s. Setup in the browser creates them once a model provider is connected.\n' "$saved" >&3
      break
    fi
    printf '  %s\n' "${saved#preset_cli: }" >&3
  done
}

finish() {
  local url code_file code="" link mode
  local origin_pattern='^https?://([A-Za-z0-9.-]+|\[[A-Fa-f0-9:]+\])(:[0-9]{1,5})?/?$'
  url="$(cat "$TEMP_DIR/ready" 2>/dev/null || true)"
  [[ -n "$url" ]] || url="http://localhost:$(manifest_value FRONTEND_PORT)"
  [[ "$url" != 'http://localhost:' ]] || url=http://localhost:3000
  [[ "$url" =~ $origin_pattern ]] || die "The ready address is invalid. Check FRONTEND_HOST and FRONTEND_PORT."
  url="${url%/}"; link="$url"
  code_file="$(cat "$TEMP_DIR/code-file" 2>/dev/null || true)"
  if [[ -n "$code_file" ]]; then
    [[ "$code_file" == /* && -f "$code_file" && ! -L "$code_file" && -O "$code_file" ]] || die "The setup-code file must be a regular file owned by you."
    if [[ "$(uname -s)" == Darwin ]]; then mode="$(stat -f '%Lp' "$code_file")"
    else mode="$(stat -c '%a' "$code_file")"; fi
    [[ "$mode" == 600 ]] || die "Protect the setup-code file with chmod 600 '$code_file'."
    code="$(< "$code_file")"
    [[ "$code" =~ ^[A-Za-z0-9_-]+$ && ${#code} -le 512 ]] || die "The setup-code file is invalid. Run the installer again to check owner setup."
    link="$url/setup#code=$code"
  fi
  printf '\n  +-- BawtHub is ready ----------------------------+\n'
  printf '  Open: %s\n' "$url"
  if [[ -n "$code" ]]; then
    if (( TTY_AVAILABLE )); then
      printf '\n  Finish owner setup: %s\n  One-time setup code: %s\n' "$link" "$code" >&3
    else
      printf '  Owner setup: %s/setup\n  Setup code is in: %s\n' "$url" "$code_file"
    fi
  fi
  sign_in_summary "$url"
  printf '  Log: %s\n  +-----------------------------------------------+\n' "$LOG_FILE"
  if [[ -n "${BAWTHUB_PACKAGED_RELEASE:-}" ]]; then
    printf '  Manage this install with bh status, bh stop, or bh start.\n'
  fi
  if (( INTERACTIVE )); then
    if [[ "$(uname -s)" == Darwin ]]; then open "$link" >/dev/null 2>&1 || true
    elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null; then
      xdg-open "$link" >/dev/null 2>&1 || true
    fi
  fi
}

main "$@"
