#!/usr/bin/env bash
# bootstrap.sh — idempotent bawthub tenant installer.
#
# Turns any Docker host into a working bawthub from one manifest (tenant.env).
# Reproduces the inst1 snowflake as a repeatable run. See deploy/README.md.
#
#   cp tenant.env.example tenant.env   # fill it in
#   ./bootstrap.sh [up|update [--pins FILE]|houses [--apply]|config|down|verify|paths|dev-reload|migrate-db|import-vault]
#
# Doors that reuse this core: local (now), cloud-init (place tenant.env + call
# this), tofu (provision box -> call this). The seam is: manifest path + this
# entrypoint. Keep both stable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$HERE/compose"
MANIFEST="${TENANT_ENV:-$HERE/tenant.env}"
ACTION="${1:-up}"
# Read from the caller's environment only, before the manifest is sourced: a
# release bundle's installer sets it for one run (see resolve_published_images).
IMAGE_MIRROR="${BAWTHUB_IMAGE_MIRROR:-}"

die() { echo "bootstrap: $*" >&2; exit 1; }
log() { echo "bootstrap: $*" >&2; }

# ── Bridge SSH identity (dev mode only) ────────────────────────────────────
# Agent bridges (claude-code/codex) run as containers that mount a
# host dir at /home/bridge/.ssh. On a fresh tenant that dir is empty, so the
# agents have no identity and cannot SSH to their own host for deploys/ops —
# this is the gap that stranded the inst1 bridge.
#
# Because bootstrap runs ON the host, it wires BOTH ends: generate a dedicated
# keypair here, then authorize it for a dedicated agent user (not the installer). The
# dev overlay mounts $BRIDGE_SSH_KEY_DIR read-only into each bridge. Idempotent:
# reuses an existing key and never double-appends the authorization line.
# ── Agent host user + opt-in host Docker (TASK-2102) ─────────────────────
# Shape shared with echo (TASK-2101): Docker access goes through sudo only, so
# deleting $DOCKER_SUDOERS revokes it. The wrapper keeps `docker` transparent.
DOCKER_SUDOERS=/etc/sudoers.d/50-docker-via-sudo
DOCKER_WRAPPER=/usr/local/bin/docker
docker_wrapper_body() {
  cat <<'EOF'
#!/bin/bash
# docker via sudo (bawthub TASK-2101/2102); revoke = rm /etc/sudoers.d/50-docker-via-sudo
[ "$(id -u)" = 0 ] && exec /usr/bin/docker "$@"
[ -w /var/run/docker.sock ] && exec /usr/bin/docker "$@"
# sudo drops the caller's env; keep it so compose interpolation, DOCKER_CONFIG
# and `-e NAME` passthrough behave as without sudo (needs SETENV in sudoers).
keep=$(compgen -e | grep -vxE 'PATH|SUDO_.*|LD_.*|BASH_FUNC_.*' | paste -sd, -)
exec /usr/bin/sudo -n ${keep:+--preserve-env="$keep"} /usr/bin/docker "$@"
EOF
}

provision_agent_user() {
  local user="$1" pub="$2"
  if [[ "$user" == "$(id -un)" ]]; then
    log "bridge ssh: WARNING BRIDGE_SSH_USER=$user is the installing user; agents get everything $user has"
    local ak="$HOME/.ssh/authorized_keys"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$ak"; chmod 600 "$ak"
    grep -qF "$pub" "$ak" || printf '%s\n' "$pub" >> "$ak"
    return 0
  fi
  if ! id "$user" >/dev/null 2>&1; then
    log "bridge ssh: creating agent user $user (no docker group; sudo may ask for your password)"
    sudo useradd --create-home --shell /bin/bash "$user" || die "bridge ssh: could not create agent user $user (needs sudo); set BRIDGE_SSH=0 to skip"
  fi
  if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
    log "bridge ssh: WARNING $user is in the docker group (root-equivalent); remove it: sudo gpasswd -d $user docker"
  fi
  local home; home="$(getent passwd "$user" | cut -d: -f6)"
  sudo install -d -m 700 -o "$user" -g "$user" "$home/.ssh" || die "bridge ssh: cannot create $home/.ssh"
  if sudo grep -qsF "$pub" "$home/.ssh/authorized_keys"; then
    log "bridge ssh: pubkey already authorized for $user"
  else
    printf '%s\n' "$pub" | sudo tee -a "$home/.ssh/authorized_keys" >/dev/null || die "bridge ssh: cannot authorize key for $user"
    log "bridge ssh: authorized pubkey for $user on $(hostname)"
  fi
  sudo chown "$user:$user" "$home/.ssh/authorized_keys" && sudo chmod 600 "$home/.ssh/authorized_keys" || die "bridge ssh: cannot set permissions on $user's authorized_keys"
  provision_agent_access "$user"
  provision_agent_docker "$user"
}

# The agent user may read the BawtHub checkout and the dev source, never write
# them: the installing user holds Docker and runs git and bootstrap.sh there, so
# agent-writable files or .git hooks would hand the agent that privilege.
# Write work belongs in the agent's own clone. Secrets stay owner-only.
provision_agent_access() {
  local user="$1" dir d ahome
  ahome="$(getent passwd "$user" | cut -d: -f6)"
  local repo; repo="$(cd "$HERE/.." && pwd)"
  for dir in "$repo" "${DEV_SOURCE_DIR:-}"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    d="$dir"
    while [[ "$d" == "$HOME"/* || "$d" == "$HOME" ]]; do  # traverse only, no listing
      [[ -O "$d" ]] && chmod o+x "$d"
      [[ "$d" == "$HOME" ]] && break
      d="$(dirname "$d")"
    done
    if sudo -u "$user" test -x "$dir"; then :; else
      log "bridge ssh: WARNING $user cannot reach $dir; grant it traverse access by hand"
    fi
    if ! sudo -u "$user" HOME="$ahome" git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$dir"; then
      sudo -u "$user" HOME="$ahome" git config --global --add safe.directory "$dir" || \
        die "bridge ssh: cannot set git safe.directory for $user"
    fi
  done
  log "bridge ssh: $user can read $repo${DEV_SOURCE_DIR:+ and $DEV_SOURCE_DIR} (write work goes in its own clone)"
}

provision_agent_docker() {
  local user="$1" line="$1 ALL=(root) NOPASSWD:SETENV: /usr/bin/docker"
  if [[ "${AGENT_HOST_DOCKER:-0}" != "1" ]]; then
    if sudo grep -qsxF "$line" "$DOCKER_SUDOERS"; then
      log "agent docker: AGENT_HOST_DOCKER is off but $DOCKER_SUDOERS still grants $user; delete that line to revoke"
    else
      log "agent docker: off (agents cannot run Docker on this host; set AGENT_HOST_DOCKER=1 to allow)"
    fi
    return 0
  fi
  {
    echo "bootstrap: ─────────────────────────────────────────────────────────"
    echo "bootstrap: WARNING AGENT_HOST_DOCKER=1 lets the AI agents run any docker"
    echo "bootstrap: command on this host as root via sudo. Docker access is full"
    echo "bootstrap: root: an agent can mount the host filesystem, read every"
    echo "bootstrap: secret and change any container. Revoke at any time:"
    echo "bootstrap:   sudo rm $DOCKER_SUDOERS"
    echo "bootstrap: ─────────────────────────────────────────────────────────"
  } >&2
  local tmp; tmp="$(mktemp)"
  sudo cat "$DOCKER_SUDOERS" 2>/dev/null | grep -vxF "$line" > "$tmp" || true
  echo "$line" >> "$tmp"
  sudo visudo -cqf "$tmp" || { rm -f "$tmp"; die "agent docker: generated sudoers failed visudo"; }
  sudo install -m 0440 -o root -g root "$tmp" "$DOCKER_SUDOERS" || { rm -f "$tmp"; die "agent docker: cannot install $DOCKER_SUDOERS"; }; rm -f "$tmp"
  docker_wrapper_body > "${tmp}.w"
  if ! sudo cmp -s "${tmp}.w" "$DOCKER_WRAPPER"; then
    [[ -e "$DOCKER_WRAPPER" ]] && ! sudo grep -q 'bawthub TASK-2101/2102' "$DOCKER_WRAPPER" && \
      { rm -f "${tmp}.w"; die "agent docker: $DOCKER_WRAPPER exists and is not ours; move it aside and re-run"; }
    sudo install -m 0755 -o root -g root "${tmp}.w" "$DOCKER_WRAPPER" || die "agent docker: cannot install $DOCKER_WRAPPER"
  fi
  rm -f "${tmp}.w"
  log "agent docker: granted $user docker via $DOCKER_SUDOERS (wrapper $DOCKER_WRAPPER)"
}

provision_bridge_ssh() {
  [[ "$MODE" == "dev" ]] || return 0            # prod tenants have no bridges
  if [[ "${BRIDGE_SSH:-1}" == "0" ]]; then
    log "bridge ssh: disabled (BRIDGE_SSH=0) — bridges will have no host identity"
    return 0
  fi
  local dir="$BRIDGE_SSH_KEY_DIR" key="$BRIDGE_SSH_KEY_DIR/id_ed25519"
  mkdir -p "$dir"; chmod 700 "$dir"
  if [[ ! -f "$key" ]]; then
    log "bridge ssh: generating dedicated ed25519 keypair → $key"
    ssh-keygen -t ed25519 -N '' -C "bawthub-bridge@$(hostname)" -f "$key" >/dev/null
  else
    log "bridge ssh: reusing existing key → $key"
  fi
  chmod 600 "$key"; chmod 644 "$key.pub"
  local pub; pub="$(cat "$key.pub")"
  # Client config lives INSIDE the key dir as `config` — ssh reads ~/.ssh/config
  # automatically, so mounting this one dir gives the bridge key + config + trust
  # in a single mount (no separate /etc/ssh/ssh_config mount needed). accept-new
  # trusts a host on first connect but still rejects a CHANGED key (safer than
  # StrictHostKeyChecking=no). User defaults to whoever ran bootstrap — the same
  # account the pubkey was just authorized on, i.e. the self-host SSH target.
  # The key is authorized on a dedicated agent user, never on the installing
  # user: that user is usually in the docker group, which is root on the host.
  local ssh_user="${BRIDGE_SSH_USER:-${AGENT_USER:-bawthub-agent}}"
  provision_agent_user "$ssh_user" "$pub"
  if [[ ! -f "$dir/config" ]]; then
    cat > "$dir/config" <<EOF
# Generated by bootstrap.sh (provision_bridge_ssh). Safe to edit; not regenerated
# once present. Delete to regenerate on the next \`up\`.
Host host.docker.internal ${BRIDGE_SSH_HOST_ALIASES:-}
    User ${ssh_user}
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
    LogLevel ERROR
EOF
    chmod 600 "$dir/config"
    log "bridge ssh: wrote client config → $dir/config (accept-new, user=$ssh_user)"
  elif grep -qE "^[[:space:]]+User $(id -un)\$" "$dir/config" && [[ "$ssh_user" != "$(id -un)" ]]; then
    # Migration: older installs pointed the bridge at the installing user.
    sed -i.bak -E "s/^([[:space:]]+User) $(id -un)\$/\1 ${ssh_user}/" "$dir/config"
    log "bridge ssh: client config now targets $ssh_user (was $(id -un); backup $dir/config.bak)"
  else
    log "bridge ssh: reusing existing client config → $dir/config"
  fi
  # Migration: remove the old self-authorization from the installing user,
  # including a legacy BRIDGE_SSH_AUTHORIZED_KEYS location.
  local old_ak
  for old_ak in "$HOME/.ssh/authorized_keys" ${BRIDGE_SSH_AUTHORIZED_KEYS:+"$BRIDGE_SSH_AUTHORIZED_KEYS"}; do
    [[ "$ssh_user" != "$(id -un)" && -f "$old_ak" ]] && grep -qF "$pub" "$old_ak" || continue
    cp -p "$old_ak" "$old_ak.bawthub-bak" || die "bridge ssh: cannot back up $old_ak"
    grep -vF "$pub" "$old_ak.bawthub-bak" > "$old_ak" || [[ $? == 1 ]] || die "bridge ssh: cannot rewrite $old_ak"
    log "bridge ssh: removed the bridge key from $old_ak (backup $old_ak.bawthub-bak)"
  done
  log "bridge ssh: mount contract → \$BRIDGE_SSH_KEY_DIR:/home/bridge/.ssh:ro (dev overlay wires this — TASK-372)"
  {
    echo "bootstrap: ─────────────────────────────────────────────────────────"
    echo "bootstrap: bridge PUBLIC key — install on any OTHER host the agents"
    echo "bootstrap: must reach (echo, LAN peers, GitHub deploy keys):"
    echo "$pub"
    echo "bootstrap: ─────────────────────────────────────────────────────────"
  } >&2
  # NOTE: this authorizes the bridge on the LOCAL host only. Reaching the host
  # from inside the container still needs host-key trust on first connect — the
  # dev overlay's ssh_config (accept-new) or a seeded known_hosts handles that.
}

# ── Retired pgcrypto vault (TASK-1477) ────────────────────────────────────
# Older tenants kept provider keys in vault.secrets (pgp_sym_encrypt) under a
# separate BAWTHUB_MASTER_KEY. The product now has ONE root, LLM_BAWT_SECRET_KEY,
# and one encrypted store (the app's CredentialStore). bootstrap no longer
# generates a master key or creates the vault. An existing vault is copied into
# the store by the one-shot `import-vault` action, which runs the app image's
# `python -m llm_bawt.vault_import`. NON-DESTRUCTIVE: the vault table and the
# master key file are never modified or deleted here; dropping them is a
# separate, irreversible operator decision made after a recorded backup.
VAULT_KEY_MOUNT=/run/bawthub-vault/master-key

import_vault() {
  local kf="$BAWTHUB_MASTER_KEY_FILE"
  if [[ ! -f "$kf" && -n "${BAWTHUB_MASTER_KEY:-}" ]]; then
    # Restoring a tenant from a pinned key: the importer reads a file only.
    store_secret "$BAWTHUB_MASTER_KEY" "$kf"
    log "import-vault: stored the master key from the environment → $kf (0600)"
  fi
  if [[ ! -f "$kf" ]]; then
    log "import-vault: no legacy vault master key at $kf; nothing to import"
    return 0
  fi
  [[ -s "$kf" ]] || die "import-vault: the master key file is empty ($kf); restore it from backup"
  [[ -n "${LLM_BAWT_SECRET_KEY:-}" ]] || \
    die "import-vault: this tenant has no app secret key yet (run ./bootstrap.sh up first)"
  if [[ "$EXTERNAL_DB" != "1" ]]; then
    log "starting local PostgreSQL (if stopped)…"
    compose up -d --wait postgres || die "local PostgreSQL did not become healthy"
  fi
  compose run --rm --no-deps -T app python -c 'import llm_bawt.vault_import' >/dev/null 2>&1 || \
    die "import-vault: the app image has no llm_bawt.vault_import; pin a newer APP_IMAGE_REF"
  log "import-vault: importing mapped vault names into the credential store (names and outcomes only)…"
  # The key reaches the one-shot only as a read-only file mount, never argv/env.
  compose run --rm --no-deps -T -v "$kf:$VAULT_KEY_MOUNT:ro" \
    -e "BAWTHUB_MASTER_KEY_FILE=$VAULT_KEY_MOUNT" \
    app python -m llm_bawt.vault_import || \
    die "import-vault: incomplete (a name failed, or two aliases hold different keys: outcome conflict); nothing was overwritten or deleted. Fix the cause (for a conflict, remove the wrong alias from the vault or connect the provider in the app) and rerun ./bootstrap.sh import-vault"
  log "import-vault: done. The vault table and $kf are left in place."
}

# ── Agent-runtime secrets (TASK-1293) ─────────────────────────────────────
# Two generate-or-reuse values, kept in the tenant secrets directory (0600):
#   LLM_BAWT_SECRET_KEY        Fernet key encrypting the app's CredentialStore
#                              (OAuth bundles, API keys). Losing it makes every
#                              stored provider credential unreadable.
#   BRIDGE_CLAUDE_TOKEN_SECRET shared secret gating the app's /v1/providers/*/token
#                              brokers; app and agent-bridge get the same value.
# The bridge never holds provider credentials; it reads them per request.

# load_secret NAME FILE: a manifest/env value must match an existing file; the
# file wins when no value is given. Never writes (config/down/verify are read-only).
load_secret() {
  local name="$1" file="$2" value="${!1:-}"
  if [[ -f "$file" ]]; then
    [[ -z "$value" || "$value" == "$(< "$file")" ]] || \
      die "$name differs from the existing value at $file; refusing to start"
    printf -v "$name" '%s' "$(< "$file")"
  fi
  export "${name?}"
}

store_secret() { # $1=value $2=file
  ( umask 077; mkdir -p "$(dirname "$2")"; printf '%s' "$1" > "$2" )
  chmod 600 "$2" 2>/dev/null || true
}

FERNET_KEY_RE='^[A-Za-z0-9_-]{43}=$'
# The app's token brokers skip authentication when this secret is empty, so an
# empty or short value must never reach compose. Generated values are 64 hex.
BRIDGE_TOKEN_RE='^[A-Za-z0-9_-]{32,}$'

# require_secret_format NAME REGEX FILE WHAT: once a value exists (supplied or
# stored), it must be well-formed. A zero-byte or truncated file from an
# interrupted write or restore fails closed instead of starting the stack.
require_secret_format() {
  local name="$1" re="$2" file="$3" what="$4" value="${!1:-}"
  [[ -f "$file" || -n "$value" ]] || return 0
  [[ "$value" =~ $re ]] || \
    die "$name is empty or malformed (from ${file} or the environment); expected $what. Restore it from backup; refusing to start"
}

provision_bridge_token_secret() {
  local file="$BRIDGE_CLAUDE_TOKEN_SECRET_FILE"
  if [[ -f "$file" ]]; then
    require_secret_format BRIDGE_CLAUDE_TOKEN_SECRET "$BRIDGE_TOKEN_RE" "$file" "32+ chars of [A-Za-z0-9_-]"
    log "bridge token secret: reusing existing secret ($file)"
    return 0
  fi
  if [[ -z "${BRIDGE_CLAUDE_TOKEN_SECRET:-}" ]]; then
    BRIDGE_CLAUDE_TOKEN_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    log "bridge token secret: GENERATED → $file (0600)"
  else
    log "bridge token secret: using value from environment"
  fi
  require_secret_format BRIDGE_CLAUDE_TOKEN_SECRET "$BRIDGE_TOKEN_RE" "$file" "32+ chars of [A-Za-z0-9_-]"
  store_secret "$BRIDGE_CLAUDE_TOKEN_SECRET" "$file"
  export BRIDGE_CLAUDE_TOKEN_SECRET
}

# An app that started before this key was provisioned generated its own into
# the app-config volume (~/.config/llm-bawt/secret.key) and encrypted stored
# credentials with it. Adopt that key instead of minting one, or every stored
# credential is orphaned. A key that disagrees with the volume's is refused.
provision_app_secret_key() {
  local file="$LLM_BAWT_SECRET_KEY_FILE" volume_key rc=0
  volume_key="$(compose run --rm --no-deps -T --entrypoint sh app -c \
    'f=/root/.config/llm-bawt/secret.key; [ -f "$f" ] || exit 3; cat "$f"')" || rc=$?
  volume_key="${volume_key//[$'\r\n ']/}"
  case "$rc" in
    0)
      [[ "$volume_key" =~ $FERNET_KEY_RE ]] || \
        die "app-config volume holds an unreadable secret.key; refusing to replace it (stored credentials depend on it)"
      if [[ -z "${LLM_BAWT_SECRET_KEY:-}" ]]; then
        LLM_BAWT_SECRET_KEY="$volume_key"
        log "app secret key: ADOPTED the existing key from the app-config volume → $file"
      elif [[ "$LLM_BAWT_SECRET_KEY" != "$volume_key" ]]; then
        die "LLM_BAWT_SECRET_KEY differs from the key in the app-config volume, which encrypted the stored credentials; refusing to start"
      fi
      ;;
    3)
      if [[ -z "${LLM_BAWT_SECRET_KEY:-}" ]]; then
        LLM_BAWT_SECRET_KEY="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_')"
        log "app secret key: GENERATED → $file (0600). This is the tenant's root secret: back it up with the database; losing it loses every stored provider credential."
      fi
      ;;
    *) die "could not read the app-config volume to check for an existing app secret key" ;;
  esac
  [[ "$LLM_BAWT_SECRET_KEY" =~ $FERNET_KEY_RE ]] || \
    die "LLM_BAWT_SECRET_KEY must be a urlsafe-base64 32-byte Fernet key (44 chars ending in '=')"
  if [[ -f "$file" ]]; then
    log "app secret key: reusing existing key ($file)"
  else
    store_secret "$LLM_BAWT_SECRET_KEY" "$file"
  fi
  export LLM_BAWT_SECRET_KEY
}

# ── 1. Load & validate manifest ────────────────────────────────────────────
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST (cp deploy/tenant.env.example deploy/tenant.env)"
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd -P)/$(basename "$MANIFEST")"
export TENANT_ENV="$MANIFEST" # Compose env_file and shell sourcing use the SAME file.
bash -n "$MANIFEST" || die "manifest has invalid shell syntax: $MANIFEST"

# ── update: repin to newer published images (TASK-1598) ────────────────────
# ./bootstrap.sh update [--pins FILE]
# Plans (KEY, FROM, TO) image pins: by default every *_IMAGE_REF in this
# checkout's tenant.env.example that differs from the manifest; with --pins,
# lines of `KEY FROM TO` (FROM `-` = key absent). Every FROM must equal the
# manifest's current value, so a pin edited since the plan refuses with
# nothing changed. Then: private backup, atomic rewrite, `up` (which ends with
# verify). If that fails the manifest is restored and `up` runs again.
# Stdout is one JSON receipt (also kept beside the backup) with the observed
# services, health and release. Exit: 0 current or updated; 3 the update
# failed and the previous pins recovered; 4 the update failed and recovery did
# not verify; 1 refused with nothing changed. Recovery restores image pins only:
# migrations the new release applied stay applied.
UPDATE_KEY_RE='^[A-Z][A-Z0-9_]*_IMAGE_REF$'
UPDATE_REF_RE='^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$'
manifest_pin() { # $1=key → last assignment's value (quotes stripped); rc 1 when absent
  local line val
  line="$(grep -E "^$1=" "$MANIFEST" | tail -1)" || return 1
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  val="${val%$'\r'}"
  if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
  printf '%s' "$val"
}
json_str() { # minimal JSON string escape for observed values
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf '"%s"' "$s"
}
# What is actually running after the attempt: each project container's service,
# image reference and Docker health, plus the frontend's release identity.
update_observed() {
  local project svc image status health sep="" out="" port rel version sha
  project="$(manifest_pin TENANT_NAME || manifest_pin COMPOSE_PROJECT_NAME || echo bawthub)"
  while IFS=$'\t' read -r svc image status; do
    [[ -n "$svc" ]] || continue
    case "$status" in
      *"(healthy)"*) health=healthy ;; *"(unhealthy)"*) health=unhealthy ;;
      *"(health: starting)"*) health=starting ;; Up*) health=running ;; *) health=down ;;
    esac
    out+="$sep{\"service\":$(json_str "$svc"),\"image\":$(json_str "$image"),\"health\":\"$health\"}"
    sep=","
  done < <(docker ps -a --filter "label=com.docker.compose.project=$project" \
    --format '{{.Label "com.docker.compose.service"}}{{"\t"}}{{.Image}}{{"\t"}}{{.Status}}' 2>/dev/null | sort)
  port="$(manifest_pin FRONTEND_PORT || echo 3000)"
  rel="$(curl -fsS --max-time 5 "http://localhost:${port}/api/health" 2>/dev/null | tr -d '\n')" || rel=""
  version="$(grep -o '"version":"[^"]*"' <<<"$rel" | head -1 | cut -d'"' -f4)" || version=""
  sha="$(grep -o '"sourceSha":"[^"]*"' <<<"$rel" | head -1 | cut -d'"' -f4)" || sha=""
  printf '"services":[%s],"release":{"version":%s,"source_sha":%s}' "$out" "$(json_str "$version")" "$(json_str "$sha")"
}
update_receipt() { # $1=outcome [$2=rollback result]; reads upd_* plan state
  local i sep="" pins="" observed='"services":[],"release":null'
  for i in "${!upd_keys[@]}"; do
    pins+="$sep{\"key\":\"${upd_keys[$i]}\",\"from\":$(json_str "${upd_from[$i]}"),\"to\":\"${upd_to[$i]}\"}"
    sep=","
  done
  [[ "$1" == current ]] || observed="$(update_observed)"
  local body
  # A rollback restores pins, never the database: `up` ran the new release's
  # migrations, so a rolled-back install runs old images on the newer schema.
  body="$(printf '{"schema":"bawthub.tenant-update/v1","outcome":"%s","rollback":%s,"migrations_reverted":false,"manifest":%s,"backup":%s,"pins":[%s],%s}' \
    "$1" "$( [[ -n "${2:-}" ]] && printf '"%s"' "$2" || printf null)" "$(json_str "$MANIFEST")" \
    "$(json_str "${upd_backup:-}")" "$pins" "$observed")"
  if [[ -n "${upd_dir:-}" && -d "$upd_dir" ]]; then
    ( umask 077; printf '%s\n' "$body" > "$upd_dir/receipt-$upd_stamp.json" )
  fi
  printf '%s\n' "$body"
}
run_update() {
  local pins_file="" example="$HERE/tenant.env.example" key from to cur i extra
  shift
  if [[ $# -gt 0 ]]; then
    [[ $# == 2 && "$1" == "--pins" && -f "$2" ]] || die "use: update [--pins FILE] (lines: KEY FROM TO)"
    pins_file="$2"
  fi
  [[ "$(manifest_pin IMAGE_SOURCE || true)" != "local" ]] || \
    die "update applies published pins; an IMAGE_SOURCE=local tenant repins with deploy/build-local.sh"
  upd_keys=(); upd_from=(); upd_to=()
  if [[ -n "$pins_file" ]]; then
    while read -r key from to extra; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      [[ -n "$to" && -z "$extra" ]] || die "update: pins lines are KEY FROM TO: $key"
      [[ "$from" == "-" ]] && from=""
      upd_keys+=("$key"); upd_from+=("$from"); upd_to+=("$to")
    done < "$pins_file"
  else
    [[ -f "$example" ]] || die "update: $example not found"
    while IFS='=' read -r key to; do
      cur="$(manifest_pin "$key" || true)"
      [[ "$cur" == "$to" ]] && continue
      upd_keys+=("$key"); upd_from+=("$cur"); upd_to+=("$to")
    done < <(grep -E '^[A-Z][A-Z0-9_]*_IMAGE_REF=' "$example")
  fi
  # Validate the whole plan before touching anything.
  for i in "${!upd_keys[@]}"; do
    key="${upd_keys[$i]}" from="${upd_from[$i]}" to="${upd_to[$i]}"
    [[ "$key" =~ $UPDATE_KEY_RE ]] || die "update: not an image pin key: $key"
    [[ "$to" =~ $UPDATE_REF_RE ]] || die "update: $key target must be a digest-pinned image (repo@sha256:<64 hex>): $to"
    [[ -z "$from" || "$from" =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "update: $key has an unexpected current value; fix the manifest first"
    for (( j=0; j<i; j++ )); do [[ "${upd_keys[$j]}" != "$key" ]] || die "update: $key listed twice"; done
  done
  if [[ ${#upd_keys[@]} == 0 ]]; then
    log "update: image pins already match; nothing to do"
    update_receipt current
    return 0
  fi
  # Refuse an undecided existing install before making a backup or staging pins.
  TENANT_ENV="$MANIFEST" "$0" check-access || die "update: choose an access mode first; no pins changed"
  # Every step below is guarded explicitly: nothing may be skipped silently.
  upd_dir="$(dirname "$MANIFEST")/.update"
  ( umask 077; mkdir -p "$upd_dir" ) || die "update: cannot create $upd_dir; nothing changed"
  mkdir "$upd_dir/lock" 2>/dev/null || die "update: another update holds $upd_dir/lock (remove it if no update is running)"
  upd_tmp="$MANIFEST.update-$$"
  trap 'rm -f "$upd_tmp" 2>/dev/null; rmdir "$upd_dir/lock" 2>/dev/null || true' EXIT
  # Check the plan against the manifest under the lock, so two updaters cannot
  # both accept the same current value.
  for i in "${!upd_keys[@]}"; do
    key="${upd_keys[$i]}" from="${upd_from[$i]}"
    cur="$(manifest_pin "$key" || true)"
    [[ "$cur" == "$from" ]] || die "update: $key changed since the plan (manifest has '${cur:-<absent>}', plan expects '${from:-<absent>}'); nothing changed"
  done
  upd_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  upd_backup="$upd_dir/tenant.env.$upd_stamp"
  cp -p "$MANIFEST" "$upd_backup" || die "update: cannot back up the manifest to $upd_backup; nothing changed"
  chmod 600 "$upd_backup" || die "update: cannot restrict $upd_backup; nothing changed"
  # Rewrite in a mode-preserving copy beside the manifest, then rename over it.
  local assigns=""
  cp -p "$MANIFEST" "$upd_tmp" || die "update: cannot write $upd_tmp; nothing changed"
  for i in "${!upd_keys[@]}"; do assigns+="${upd_keys[$i]}=${upd_to[$i]}"$'\n'; done
  UPD_ASSIGNS="$assigns" awk '
    BEGIN { n = split(ENVIRON["UPD_ASSIGNS"], a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") { k = substr(a[i], 1, index(a[i], "=") - 1); want[k] = a[i]; order[++m] = k } }
    { k = $0; sub(/=.*/, "", k)
      if ((k in want) && $0 ~ /^[A-Z][A-Z0-9_]*=/) { print want[k]; seen[k] = 1; next }
      print }
    END { for (i = 1; i <= m; i++) if (!(order[i] in seen)) print want[order[i]] }
  ' "$MANIFEST" > "$upd_tmp" || die "update: cannot rewrite the manifest; nothing changed"
  bash -n "$upd_tmp" || die "update: rewritten manifest failed a syntax check; nothing changed"
  mv -f "$upd_tmp" "$MANIFEST" || die "update: cannot replace $MANIFEST; nothing changed"
  for i in "${!upd_keys[@]}"; do log "update: ${upd_keys[$i]} ${upd_from[$i]:-<absent>} -> ${upd_to[$i]}"; done
  # Child runs reload the rewritten manifest; their output goes to stderr so
  # stdout carries only the JSON receipt.
  if TENANT_ENV="$MANIFEST" "$0" up >&2; then
    update_receipt updated
    return 0
  fi
  log "update: FAILED; restoring the previous manifest ($upd_backup) and starting it again"
  log "update: database migrations the new release applied are NOT reverted"
  if ! { cp -p "$upd_backup" "$upd_tmp" && mv -f "$upd_tmp" "$MANIFEST"; }; then
    log "update: could not restore the manifest; copy $upd_backup over $MANIFEST by hand, then run ./bootstrap.sh up"
    update_receipt update_failed recovery_failed
    return 4
  fi
  if TENANT_ENV="$MANIFEST" "$0" up >&2; then
    update_receipt update_failed recovered
    return 3
  fi
  log "update: the previous pins did not come back healthy either; inspect with ./bootstrap.sh verify"
  update_receipt update_failed recovery_failed
  return 4
}
if [[ "$ACTION" == "update" ]]; then
  # Called plainly (not in a `||` list) so errexit stays active inside it.
  run_update "$@"
  exit 0
fi

set -a; # shellcheck disable=SC1090
source "$MANIFEST"; set +a
# A manifest can assign TENANT_ENV too; pin the resolved caller-selected file.
export TENANT_ENV="$MANIFEST"

MODE="${MODE:-}"
[[ "$MODE" == "prod" || "$MODE" == "dev" ]] || die "MODE must be prod or dev (got: $MODE)"
TENANT_NAME="${TENANT_NAME:-${COMPOSE_PROJECT_NAME:-bawthub}}"
[[ "$TENANT_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "TENANT_NAME must start with a lowercase letter or digit and contain only lowercase letters, digits, '-' or '_' (max 48 chars)"
export TENANT_NAME

# Existing tenants must choose access explicitly; share this check with update
# preflight, before validating pins (an update may supply missing pins).
if [[ "$TENANT_NAME" == "bawthub" ]]; then
  BAWTHUB_MASTER_KEY_FILE="${BAWTHUB_MASTER_KEY_FILE:-$HERE/.master-key}"
else
  BAWTHUB_MASTER_KEY_FILE="${BAWTHUB_MASTER_KEY_FILE:-$HOME/.config/bawthub/$TENANT_NAME/.master-key}"
fi
SECRETS_DIR="$(dirname "$BAWTHUB_MASTER_KEY_FILE")"
LLM_BAWT_SECRET_KEY_FILE="${LLM_BAWT_SECRET_KEY_FILE:-$SECRETS_DIR/.llm-bawt-secret-key}"
BRIDGE_CLAUDE_TOKEN_SECRET_FILE="${BRIDGE_CLAUDE_TOKEN_SECRET_FILE:-$SECRETS_DIR/.bridge-token-secret}"
export BAWTHUB_MASTER_KEY_FILE LLM_BAWT_SECRET_KEY_FILE BRIDGE_CLAUDE_TOKEN_SECRET_FILE
ACCESS_FILE="$SECRETS_DIR/.access"

existing_install() { # 0 = existing (or cannot tell), 1 = fresh
  local ids
  [[ ! -e "$LLM_BAWT_SECRET_KEY_FILE" && ! -e "$BRIDGE_CLAUDE_TOKEN_SECRET_FILE" ]] || return 0
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$TENANT_NAME" 2>/dev/null)" || return 0
  [[ -z "$ids" ]] || return 0
  ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$TENANT_NAME" 2>/dev/null)" || return 0
  [[ -z "$ids" ]] || return 0
  return 1
}
FRESH_INSTALL="" # decided on first use: 1 fresh, 0 existing or unknown
fresh_install() {
  if [[ -z "$FRESH_INSTALL" ]]; then
    if existing_install; then FRESH_INSTALL=0; else FRESH_INSTALL=1; fi
  fi
  [[ "$FRESH_INSTALL" == "1" ]]
}
resolve_access() {
  if [[ -z "${ACCESS:-}" && -f "$ACCESS_FILE" ]]; then
    ACCESS="$(< "$ACCESS_FILE")"
    [[ "$ACCESS" == "signin" || "$ACCESS" == "trusted-lan" ]] || \
      die "$ACCESS_FILE holds an unknown access mode; set ACCESS=signin or ACCESS=trusted-lan in $MANIFEST"
  fi
  if [[ -z "${ACCESS:-}" ]]; then
    if fresh_install; then
      ACCESS=signin
    elif [[ "$ACTION" == "up" || "$ACTION" == "dev-reload" || "$ACTION" == "check-access" ]]; then
      die "this tenant already exists (secrets, containers or volumes for project $TENANT_NAME) and no access mode is chosen. Set ACCESS=signin (every user signs in; app API and MCP on loopback only) or ACCESS=trusted-lan (the earlier sessionless behavior, trusted network only) in $MANIFEST and rerun. Nothing was changed."
    else
      # Read-only actions on an undecided existing install keep its behavior.
      ACCESS=trusted-lan
    fi
  fi
  [[ "$ACCESS" == "signin" || "$ACCESS" == "trusted-lan" ]] || \
    die "ACCESS must be signin or trusted-lan (got: $ACCESS)"
  export ACCESS
}
if [[ "$ACTION" == "check-access" ]]; then
  resolve_access
  exit 0
fi

if [[ "${GPU:-0}" != "0" ]]; then
  die "GPU=${GPU} is not supported by the CPU tenant installer (no GPU overlay is wired)"
fi
[[ -z "${EXTERNAL_REDIS_URL:-}" ]] || die "EXTERNAL_REDIS_URL is not implemented; leave it unset"

# Reject every missing/placeholder setting before generating keys or starting
# any containers. Provider keys are optional; a configured placeholder is not.
required=()
missing() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" && "$value" != *PLACEHOLDER* && "$value" != '<'* ]] || required+=("$name")
}
external_config=0
for key in EXTERNAL_POSTGRES_HOST EXTERNAL_POSTGRES_PORT EXTERNAL_POSTGRES_USER EXTERNAL_POSTGRES_PASSWORD EXTERNAL_POSTGRES_DATABASE EXTERNAL_FRONTEND_DATABASE_URL; do
  [[ -z "${!key:-}" ]] || external_config=1
done
if [[ "$external_config" == "1" ]]; then
  for key in EXTERNAL_POSTGRES_HOST EXTERNAL_POSTGRES_USER EXTERNAL_POSTGRES_PASSWORD EXTERNAL_POSTGRES_DATABASE EXTERNAL_FRONTEND_DATABASE_URL; do missing "$key"; done
elif [[ -n "${LLM_BAWT_POSTGRES_PASSWORD:-}" ]]; then
  # Optional: unset means the stored or (new install) generated password.
  missing LLM_BAWT_POSTGRES_PASSWORD
fi
for key in OPENAI_API_KEY ANTHROPIC_API_KEY LLM_BAWT_XAI_API_KEY \
  LLM_BAWT_POSTGRES_USER LLM_BAWT_POSTGRES_DATABASE FRONTEND_POSTGRES_DATABASE \
  AGENT_ORIGIN FRONTEND_HOST EMBED_IMAGE APP_IMAGE_REF TENANT_FRONTEND_IMAGE_REF \
  BAWTHUB_MASTER_KEY BAWTHUB_MASTER_KEY_FILE LLM_BAWT_SECRET_KEY BRIDGE_CLAUDE_TOKEN_SECRET \
  AGENT_BRIDGE_IMAGE_REF; do
  if [[ -n "${!key:-}" ]]; then missing "$key"; fi
done
[[ -z "${required[*]-}" ]] || die "missing or placeholder manifest values: ${required[*]} ($MANIFEST)"

for port_name in SERVICE_PORT MCP_PORT FRONTEND_PORT EXTERNAL_POSTGRES_PORT; do
  port="${!port_name:-}"
  if [[ -n "$port" ]] && { [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); }; then
    die "$port_name must be a TCP port from 1 to 65535"
  fi
done
AGENT_ORIGIN="${AGENT_ORIGIN:-http://${FRONTEND_HOST:-localhost}:${FRONTEND_PORT:-3000}}"
export AGENT_ORIGIN

# URL-encode credentials for the local frontend connection (Compose must not
# interpolate a raw '#' or '@' into a PostgreSQL URL).
url_encode() {
  local value="$1" byte hex i
  local LC_ALL=C
  REPLY=""
  for ((i=0; i<${#value}; i++)); do
    byte="${value:i:1}"
    if [[ "$byte" == [a-zA-Z0-9._~-] ]]; then REPLY+="$byte"
    else printf -v hex '%%%02X' "'$byte"; REPLY+="$hex"
    fi
  done
}

VOICE="${VOICE:-pocket}"
[[ "$VOICE" == "pocket" || "$VOICE" == "external" || "$VOICE" == "off" ]] || \
  die "VOICE must be pocket, external or off (got: $VOICE)"
# IMAGE_SOURCE=published (default) accepts only immutable GHCR digests.
# IMAGE_SOURCE=local is the dev loop: app/frontend may also be images built on
# THIS Docker host by deploy/build-local.sh. The localhost/ registry prefix can
# never resolve to Docker Hub, so a missing local image fails instead of
# pulling a look-alike. A local-image tenant is a test tenant, not a release.
IMAGE_SOURCE="${IMAGE_SOURCE:-published}"
[[ "$IMAGE_SOURCE" == "published" || "$IMAGE_SOURCE" == "local" ]] || \
  die "IMAGE_SOURCE must be published or local (got: $IMAGE_SOURCE)"
LOCAL_TAG_RE='[0-9a-f]{7,40}(-dirty-[0-9a-f]{12})?'
local_image_ref() { # $1=ref $2=app|frontend
  [[ "$IMAGE_SOURCE" == "local" && "$1" =~ ^localhost/bawthub/$2:${LOCAL_TAG_RE}$ ]]
}
if ! local_image_ref "${APP_IMAGE_REF:-}" app; then
  [[ "${APP_IMAGE_REF:-}" =~ ^ghcr\.io/bawthub/app@sha256:[0-9a-f]{64}$ ]] || \
    die "APP_IMAGE_REF must be a published ghcr.io/bawthub/app@sha256:<64 hex> (or localhost/bawthub/app:<sha> with IMAGE_SOURCE=local)"
fi
# Existing tenant pins remain valid until migrated. New releases use the
# canonical frontend package; both paths still require an immutable digest.
if ! local_image_ref "${TENANT_FRONTEND_IMAGE_REF:-}" frontend; then
  [[ "${TENANT_FRONTEND_IMAGE_REF:-}" =~ ^ghcr\.io/bawthub/(frontend|tenant-frontend)@sha256:[0-9a-f]{64}$ ]] || \
    die "TENANT_FRONTEND_IMAGE_REF must be ghcr.io/bawthub/frontend@sha256:<64 hex> (legacy tenant-frontend digests remain accepted; localhost/bawthub/frontend:<sha> with IMAGE_SOURCE=local)"
fi
# Every tenant runs one agent bridge: the wizard's first bot is an agent.
if ! local_image_ref "${AGENT_BRIDGE_IMAGE_REF:-}" agent-bridge; then
  [[ "${AGENT_BRIDGE_IMAGE_REF:-}" =~ ^ghcr\.io/bawthub/agent-bridge@sha256:[0-9a-f]{64}$ ]] || \
    die "AGENT_BRIDGE_IMAGE_REF must be a published ghcr.io/bawthub/agent-bridge@sha256:<64 hex> (or localhost/bawthub/agent-bridge:<sha> with IMAGE_SOURCE=local)"
fi
# Optional CPU embed sidecar (TASK-2448). Our published image must be pinned by
# digest like the others; an operator's own image elsewhere is accepted as given.
if [[ -n "${EMBED_IMAGE:-}" ]] && ! local_image_ref "$EMBED_IMAGE" embed; then
  if [[ "$EMBED_IMAGE" == ghcr.io/bawthub/* ]]; then
    [[ "$EMBED_IMAGE" =~ ^ghcr\.io/bawthub/embed@sha256:[0-9a-f]{64}$ ]] || \
      die "EMBED_IMAGE must be a published ghcr.io/bawthub/embed@sha256:<64 hex> (or localhost/bawthub/embed:<sha> with IMAGE_SOURCE=local), or leave it unset"
  fi
fi
# The ops runner (TASK-2128) launches one job worker container per approved
# action from this immutable image; it is not a Compose service, so bootstrap
# pulls it explicitly.
TENANT_OPS="${TENANT_OPS:-1}"
[[ "$TENANT_OPS" == "0" || "$TENANT_OPS" == "1" ]] || die "TENANT_OPS must be 0 or 1"
if [[ "$TENANT_OPS" == "1" ]]; then
  [[ "${OPS_WORKER_IMAGE_REF:-}" =~ ^(ghcr\.io/bawthub/ops-worker@sha256:[0-9a-f]{64}|sha256:[0-9a-f]{64})$ ]] || \
    die "OPS_WORKER_IMAGE_REF must be a published ghcr.io/bawthub/ops-worker@sha256:<64 hex> (or a local sha256:<64 hex> image ID), or set TENANT_OPS=0"
  export OPS_WORKER_IMAGE_REF
fi
# Agent tools (TASK-2130): CPU Playwright MCP and Crawl4AI, on by default.
# Third-party images, pinned by digest like every other tenant image.
AGENT_TOOLS="${AGENT_TOOLS:-1}"
[[ "$AGENT_TOOLS" == "0" || "$AGENT_TOOLS" == "1" ]] || die "AGENT_TOOLS must be 0 or 1"
if [[ "$AGENT_TOOLS" == "1" ]]; then
  [[ "${PLAYWRIGHT_MCP_IMAGE_REF:-}" =~ ^(docker\.io/)?mcp/playwright(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] || \
    die "PLAYWRIGHT_MCP_IMAGE_REF must be a digest-pinned mcp/playwright@sha256:<64 hex>, or set AGENT_TOOLS=0"
  [[ "${CRAWL4AI_IMAGE_REF:-}" =~ ^(docker\.io/)?unclecode/crawl4ai(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] || \
    die "CRAWL4AI_IMAGE_REF must be a digest-pinned unclecode/crawl4ai@sha256:<64 hex>, or set AGENT_TOOLS=0"
fi
if [[ "$IMAGE_SOURCE" == "local" ]]; then
  log "IMAGE_SOURCE=local — TEST TENANT: app=$APP_IMAGE_REF frontend=$TENANT_FRONTEND_IMAGE_REF agent-bridge=$AGENT_BRIDGE_IMAGE_REF"
fi
if [[ "$VOICE" == "pocket" ]]; then
  [[ "${POCKET_IMAGE_REF:-}" =~ ^ghcr\.io/bawthub/pocket-tts@sha256:[0-9a-f]{64}$ ]] || \
    die "POCKET_IMAGE_REF must be a published ghcr.io/bawthub/pocket-tts@sha256:<64 hex>"
  [[ "${VOICE_BACKEND_IMAGE_REF:-}" =~ ^ghcr\.io/bawthub/voice-backend@sha256:[0-9a-f]{64}$ ]] || \
    die "VOICE_BACKEND_IMAGE_REF must be a published ghcr.io/bawthub/voice-backend@sha256:<64 hex>"
  if [[ -n "${CPU_STT_IMAGE_REF:-}" ]]; then
    [[ "$CPU_STT_IMAGE_REF" =~ ^ghcr\.io/bawthub/cpu-stt@sha256:[0-9a-f]{64}$ ]] || \
      die "CPU_STT_IMAGE_REF must be a published ghcr.io/bawthub/cpu-stt@sha256:<64 hex>"
  fi
fi
if [[ "$VOICE" == "external" ]]; then
  [[ "${EXTERNAL_VOICE_URL:-}" =~ ^https?://[^/@]+$ ]] || \
    die "EXTERNAL_VOICE_URL must be a credential-free HTTP(S) origin for VOICE=external"
fi

# Bridge SSH key dir — exported so the dev overlay can mount it in any action
# (config/up/down). Defaults beside the manifest (gitignored). The keypair is
# only generated + self-authorized on `up` in dev (see provision_bridge_ssh).
BRIDGE_SSH_KEY_DIR="${BRIDGE_SSH_KEY_DIR:-$HERE/.bridge-ssh}"
export BRIDGE_SSH_KEY_DIR
if [[ "$MODE" == "dev" ]]; then
  [[ "${DEV_SOURCE_DIR:-}" == /* && -d "${DEV_SOURCE_DIR:-}/src" && -f "${DEV_SOURCE_DIR:-}/pyproject.toml" && -f "${DEV_SOURCE_DIR:-}/uv.lock" && -f "${DEV_SOURCE_DIR:-}/server.sh" && -f "${DEV_SOURCE_DIR:-}/README.md" && -f "${DEV_SOURCE_DIR:-}/LICENSE" ]] || \
    die "MODE=dev requires an absolute DEV_SOURCE_DIR with src/, pyproject.toml, uv.lock, server.sh, README.md and LICENSE"
  export DEV_SOURCE_DIR
fi
# Optional HMR frontend (TASK-347): a VM-local bawthub frontend/ checkout
# replaces the pinned frontend image. Unset keeps the image.
DEV_FRONTEND=0
if [[ -n "${DEV_FRONTEND_SOURCE_DIR:-}" ]]; then
  [[ "$MODE" == "dev" ]] || die "DEV_FRONTEND_SOURCE_DIR requires MODE=dev"
  [[ "$DEV_FRONTEND_SOURCE_DIR" == /* && -f "$DEV_FRONTEND_SOURCE_DIR/package.json" && -f "$DEV_FRONTEND_SOURCE_DIR/pnpm-lock.yaml" && -f "$DEV_FRONTEND_SOURCE_DIR/hot-reloading.Dockerfile" && -f "$DEV_FRONTEND_SOURCE_DIR/scripts/dev-deps-sync.sh" && -f "$DEV_FRONTEND_SOURCE_DIR/prisma/schema.prisma" ]] || \
    die "DEV_FRONTEND_SOURCE_DIR must be an absolute bawthub frontend/ directory (package.json, pnpm-lock.yaml, hot-reloading.Dockerfile, scripts/dev-deps-sync.sh, prisma/schema.prisma)"
  export DEV_FRONTEND_SOURCE_DIR
  DEV_FRONTEND=1
fi

# The tenant secrets directory. Its path is still named after the retired vault
# master key, so existing tenants keep their secrets where they are: the default
# project beside the manifest, other tenants outside the source tree in a
# per-project directory. Only `import-vault` reads the legacy key itself.
if [[ -f "$BAWTHUB_MASTER_KEY_FILE" ]]; then
  if [[ -n "${BAWTHUB_MASTER_KEY:-}" && "$BAWTHUB_MASTER_KEY" != "$(< "$BAWTHUB_MASTER_KEY_FILE")" ]]; then
    die "BAWTHUB_MASTER_KEY differs from the existing key at $BAWTHUB_MASTER_KEY_FILE"
  fi
fi
if [[ "$ACTION" == "paths" ]]; then
  # Scope for the installer's uninstall (TASK-2507): read-only, no Docker.
  printf 'TENANT_NAME=%s\nPROJECT=%s\nSECRETS_DIR=%s\nMANIFEST=%s\nDEPLOY_DIR=%s\n' \
    "$TENANT_NAME" "$TENANT_NAME" "$SECRETS_DIR" "$MANIFEST" "$HERE"
  # The session override exactly as up will see it (sourced manifest plus
  # inherited environment), before the access mode fills in a default.
  printf 'AUTH_SESSIONS=%s\n' "${BAWTHUB_AUTH_SESSIONS:-}"
  exit 0
fi
load_secret LLM_BAWT_SECRET_KEY "$LLM_BAWT_SECRET_KEY_FILE"
load_secret BRIDGE_CLAUDE_TOKEN_SECRET "$BRIDGE_CLAUDE_TOKEN_SECRET_FILE"
require_secret_format LLM_BAWT_SECRET_KEY "$FERNET_KEY_RE" "$LLM_BAWT_SECRET_KEY_FILE" \
  "a urlsafe-base64 32-byte Fernet key (44 chars ending in '=')"
require_secret_format BRIDGE_CLAUDE_TOKEN_SECRET "$BRIDGE_TOKEN_RE" "$BRIDGE_CLAUDE_TOKEN_SECRET_FILE" \
  "32+ chars of [A-Za-z0-9_-]"

# ── Access posture (TASK-2390) ─────────────────────────────────────────────
bare_origin_ok() { # http(s)://host[:port], port 1–65535, nothing else
  local port
  [[ "$1" =~ ^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:([0-9]{1,5}))?$ ]] || return 1
  port="${BASH_REMATCH[3]}"
  [[ -z "$port" ]] || (( 10#$port >= 1 && 10#$port <= 65535 ))
}
resolve_access

if [[ "$ACCESS" == "signin" ]]; then
  # Only fill in what the manifest left unset; weaker explicit values stay the
  # operator's choice but are called out.
  : "${BAWTHUB_AUTH_SESSIONS:=on}"
  : "${BAWTHUB_IDENTITY_HEADERS:=untrusted}"
  : "${BAWTHUB_UNAUTHENTICATED_SUBJECT_POLICY:=anonymous}"
  [[ "$BAWTHUB_AUTH_SESSIONS" == "on" ]] || \
    log "WARNING ACCESS=signin but BAWTHUB_AUTH_SESSIONS=$BAWTHUB_AUTH_SESSIONS: nobody can sign in"
  [[ "$BAWTHUB_IDENTITY_HEADERS" == "untrusted" ]] || \
    log "WARNING BAWTHUB_IDENTITY_HEADERS=$BAWTHUB_IDENTITY_HEADERS: only safe behind an authenticating proxy that strips client identity headers"
  [[ "$BAWTHUB_UNAUTHENTICATED_SUBJECT_POLICY" == "anonymous" ]] || \
    log "WARNING BAWTHUB_UNAUTHENTICATED_SUBJECT_POLICY=$BAWTHUB_UNAUTHENTICATED_SUBJECT_POLICY: visitors without a session can pick a user"
  [[ -n "${BAWTHUB_AUTH_URL:-}" ]] || BAWTHUB_AUTH_URL="${LLM_BAWT_PUBLIC_ORIGIN:-$AGENT_ORIGIN}"
  # The frontend accepts only a bare origin (one optional trailing '/'): no
  # credentials, path, query or fragment; a port must be 1–65535. Check the
  # same here so a bad origin fails before up changes anything.
  BAWTHUB_AUTH_URL="${BAWTHUB_AUTH_URL%/}"
  bare_origin_ok "$BAWTHUB_AUTH_URL" || \
    die "ACCESS=signin needs a bare http(s) sign-in origin such as https://hub.example.com[:port]; set LLM_BAWT_PUBLIC_ORIGIN or BAWTHUB_AUTH_URL (got: ${BAWTHUB_AUTH_URL:-nothing})"
  [[ ! "$BAWTHUB_AUTH_URL" =~ ^https?://(localhost|127\.0\.0\.1)(:|$) ]] || \
    log "WARNING sign-in origin is $BAWTHUB_AUTH_URL: sign-in works only from this machine; set FRONTEND_HOST, AGENT_ORIGIN or LLM_BAWT_PUBLIC_ORIGIN to the address people open"
  export BAWTHUB_AUTH_SESSIONS BAWTHUB_IDENTITY_HEADERS BAWTHUB_UNAUTHENTICATED_SUBJECT_POLICY BAWTHUB_AUTH_URL
  # Owner setup code held by the installer (TASK-2507): created once on `up`,
  # 0600, and passed to the frontend, which pins the pending setup to it. It
  # survives restarts, never appears in a log, and is useless once the owner
  # exists. Delete the file and run `up` again to replace it.
  OWNER_SETUP_CODE_FILE="$SECRETS_DIR/.owner-setup-code"
  if [[ ! -f "$OWNER_SETUP_CODE_FILE" && "$ACTION" == "up" ]]; then
    code="$( { LC_ALL=C tr -dc 'ABCDEFGHJKMNPQRSTVWXYZ23456789' < /dev/urandom 2>/dev/null | head -c 20; } || true)"
    [[ ${#code} == 20 ]] || die "could not generate the owner setup code"
    store_secret "${code:0:4}-${code:4:4}-${code:8:4}-${code:12:4}-${code:16:4}" "$OWNER_SETUP_CODE_FILE"
    unset code
  fi
  BAWTHUB_OWNER_SETUP_CODE=""
  [[ ! -f "$OWNER_SETUP_CODE_FILE" ]] || BAWTHUB_OWNER_SETUP_CODE="$(< "$OWNER_SETUP_CODE_FILE")"
  export BAWTHUB_OWNER_SETUP_CODE
fi
# House previews: signin tenants put each house's preview port behind the
# sign-in gate (a signed-in user gets a one-use link from the frontend);
# trusted-lan keeps the earlier open preview. Opt-out: BAWT_HOUSE_PREVIEW_GATE=off.
if [[ "$ACCESS" == "signin" ]]; then
  : "${BAWT_HOUSE_PREVIEW_GATE:=on}"
  [[ "$BAWT_HOUSE_PREVIEW_GATE" == "on" ]] || \
    log "WARNING ACCESS=signin but BAWT_HOUSE_PREVIEW_GATE=$BAWT_HOUSE_PREVIEW_GATE: house previews are open to anyone who can reach their ports"
else
  : "${BAWT_HOUSE_PREVIEW_GATE:=off}"
fi
[[ "$BAWT_HOUSE_PREVIEW_GATE" == "on" || "$BAWT_HOUSE_PREVIEW_GATE" == "off" ]] || \
  die "BAWT_HOUSE_PREVIEW_GATE must be on or off (got: $BAWT_HOUSE_PREVIEW_GATE)"
export BAWT_HOUSE_PREVIEW_GATE
# llm-bawt enforcement: signin tenants require a credential on the app API
# (8642) and MCP (8001) and refuse unlisted Host headers. The two auth modes
# are only defaults while no settings row exists, so verify reads the
# effective modes from the app. Opt-out: set that one variable in the manifest.
# trusted-lan leaves all three at the app's own defaults.
ENFORCE_VARS=(LLM_BAWT_API_AUTH_MODE LLM_BAWT_MCP_AUTH_MODE LLM_BAWT_HOST_GUARD)
# The app reads an unknown auth mode as off, so a typo must stop here.
for var in "${ENFORCE_VARS[@]}"; do
  value="${!var:-}"
  if [[ "$var" == "LLM_BAWT_HOST_GUARD" ]]; then
    [[ -z "$value" || "$value" == "enforce" || "$value" == "report" || "$value" == "off" ]] || \
      die "LLM_BAWT_HOST_GUARD must be enforce, report or off (got: $value)"
  else
    [[ -z "$value" || "$value" == "enforce" || "$value" == "log" || "$value" == "off" ]] || \
      die "$var must be enforce, log or off (got: $value)"
  fi
done
if [[ "$ACCESS" == "signin" ]]; then
  for var in "${ENFORCE_VARS[@]}"; do
    [[ -n "${!var:-}" ]] || printf -v "$var" enforce
    [[ "${!var}" == "enforce" ]] || \
      log "WARNING ACCESS=signin but $var=${!var}: not enforced, so the app accepts requests it would otherwise refuse"
    export "${var?}"
  done
  # The sign-in host may reach the app by that name; loopback and the Compose
  # service name are always allowed.
  if [[ -z "${LLM_BAWT_ALLOWED_HOSTS:-}" ]]; then
    LLM_BAWT_ALLOWED_HOSTS="$(sed -E 's#^https?://(\[[^]]*\]|[^:/]*).*$#\1#; s#^\[(.*)\]$#\1#' <<<"$BAWTHUB_AUTH_URL")"
    export LLM_BAWT_ALLOWED_HOSTS
  fi
  [[ "${BAWTHUB_ORIGIN_CHECK:-enforce}" != "off" && "${BAWTHUB_ORIGIN_CHECK:-enforce}" != "report" ]] || \
    log "WARNING ACCESS=signin but BAWTHUB_ORIGIN_CHECK=$BAWTHUB_ORIGIN_CHECK: other websites can send writes to BawtHub as a signed-in user"
fi
# The app API (8642) and MCP (8001) publish on loopback unless the operator
# opts out; the frontend, houses and voice reach the app on the Compose network.
PUBLISH_APP_PORTS="${PUBLISH_APP_PORTS:-0}"
[[ "$PUBLISH_APP_PORTS" == "0" || "$PUBLISH_APP_PORTS" == "1" ]] || die "PUBLISH_APP_PORTS must be 0 or 1"
if [[ "$ACCESS" == "trusted-lan" || "$PUBLISH_APP_PORTS" == "1" ]]; then
  APP_PUBLISH_PREFIX=""
else
  APP_PUBLISH_PREFIX="127.0.0.1:"
fi
export APP_PUBLISH_PREFIX
log "access: $ACCESS (app API and MCP ports: ${APP_PUBLISH_PREFIX:-all interfaces})"

# Any EXTERNAL_POSTGRES_* setting selects external mode; incomplete settings
# were rejected above, so we never silently boot against the local DB instead.
EXTERNAL_DB=0
if [[ "$external_config" == "1" ]]; then
  EXTERNAL_DB=1
  [[ -n "${EXTERNAL_FRONTEND_DATABASE_URL:-}" ]] || \
    die "EXTERNAL_POSTGRES_HOST is set but EXTERNAL_FRONTEND_DATABASE_URL is not — the frontend needs its own DB URL"
else
  # The local DB password lives 0600 beside the other tenant secrets. A
  # manifest value still works and must match a stored one. Only a brand-new
  # install gets a generated password (stored by up before PostgreSQL first
  # starts); an existing database's password is never invented.
  LLM_BAWT_POSTGRES_PASSWORD_FILE="$SECRETS_DIR/.postgres-password"
  load_secret LLM_BAWT_POSTGRES_PASSWORD "$LLM_BAWT_POSTGRES_PASSWORD_FILE"
  if [[ -f "$LLM_BAWT_POSTGRES_PASSWORD_FILE" && -z "${LLM_BAWT_POSTGRES_PASSWORD:-}" ]]; then
    die "$LLM_BAWT_POSTGRES_PASSWORD_FILE is empty; restore it from backup (or set LLM_BAWT_POSTGRES_PASSWORD in $MANIFEST and remove the empty file)"
  fi
  if [[ -z "${LLM_BAWT_POSTGRES_PASSWORD:-}" ]]; then
    if [[ "$ACTION" == "config" ]] && fresh_install; then
      # Validating a new install before its first up: render with a marker,
      # never stored; up generates and stores the real password.
      LLM_BAWT_POSTGRES_PASSWORD="generated-by-first-up"
    elif [[ "$ACTION" != "up" ]]; then
      die "no local DB password yet; run ./bootstrap.sh up first (it generates one for a new install)"
    elif fresh_install; then
      LLM_BAWT_POSTGRES_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      POSTGRES_PASSWORD_GENERATED=1
    else
      die "this tenant already has data but its local DB password is neither in $MANIFEST nor in $LLM_BAWT_POSTGRES_PASSWORD_FILE. Put the existing password in LLM_BAWT_POSTGRES_PASSWORD (or that file, mode 0600) and rerun; bootstrap never replaces an existing database password."
    fi
  fi
  export LLM_BAWT_POSTGRES_PASSWORD
  [[ "${FRONTEND_POSTGRES_DATABASE:-bawthub_frontend}" != "${LLM_BAWT_POSTGRES_DATABASE:-llm_bawt}" ]] || \
    die "FRONTEND_POSTGRES_DATABASE must differ from LLM_BAWT_POSTGRES_DATABASE"
  [[ "${LLM_BAWT_POSTGRES_HOST:-postgres}" == "postgres" && "${LLM_BAWT_POSTGRES_PORT:-5432}" == "5432" ]] || \
    die "local DB mode requires the app to use postgres:5432 (use EXTERNAL_POSTGRES_* for external DBs)"
fi
if [[ "$EXTERNAL_DB" == "1" ]]; then
  FRONTEND_DATABASE_URL="$EXTERNAL_FRONTEND_DATABASE_URL"
else
  url_encode "${LLM_BAWT_POSTGRES_USER:-llm_bawt}"; db_user_url="$REPLY"
  url_encode "$LLM_BAWT_POSTGRES_PASSWORD"; db_password_url="$REPLY"
  url_encode "${FRONTEND_POSTGRES_DATABASE:-bawthub_frontend}"; db_name_url="$REPLY"
  FRONTEND_DATABASE_URL="postgresql://${db_user_url}:${db_password_url}@postgres:5432/${db_name_url}?schema=public"
fi
export FRONTEND_DATABASE_URL
# Pocket's catalog uses the SAME per-tenant Prisma DB as the frontend.
VOICE_DATABASE_URL="$FRONTEND_DATABASE_URL"
export VOICE_DATABASE_URL

# App-DB connection settings for the one-shot DB tools (preflight, inventory),
# passed into the frontend container by name, never on a command line.
app_db_env() {
  if [[ "$EXTERNAL_DB" == "1" ]]; then
    DB_APP_HOST="$EXTERNAL_POSTGRES_HOST"
    DB_APP_PORT="${EXTERNAL_POSTGRES_PORT:-5432}"
    DB_APP_USER="$EXTERNAL_POSTGRES_USER"
    DB_APP_PASSWORD="$EXTERNAL_POSTGRES_PASSWORD"
    DB_APP_DATABASE="$EXTERNAL_POSTGRES_DATABASE"
    DB_INIT_CREATE=0
  else
    DB_APP_HOST=postgres
    DB_APP_PORT=5432
    DB_APP_USER="${LLM_BAWT_POSTGRES_USER:-llm_bawt}"
    DB_APP_PASSWORD="$LLM_BAWT_POSTGRES_PASSWORD"
    DB_APP_DATABASE="${LLM_BAWT_POSTGRES_DATABASE:-llm_bawt}"
    DB_INIT_CREATE=1
  fi
  export DB_APP_HOST DB_APP_PORT DB_APP_USER DB_APP_PASSWORD DB_APP_DATABASE DB_INIT_CREATE
}

# ── Houses (TASK-2129) ────────────────────────────────────────────────────
# HOUSES capped agent containers (default 2; 0 = none), each its own Compose
# service house-h<N> on the agent-bridge image, sharing the bridge's
# workspace and session volumes. A bot moves in with its self_house tool; an
# emptied house restarts itself. Each house publishes its preview (Vite +
# Hono from a task worktree, `house-preview`) on its own host port, so the
# preview origin is the tenant's own scheme and host with that port.
# Desired files are disposable; only the shared reconciler publishes them into
# deploy/.generated/<tenant> after checking live identity and occupancy.
HOUSES="${HOUSES:-2}"
[[ "$HOUSES" =~ ^[0-9]{1,2}$ ]] && (( 10#$HOUSES <= 16 )) || die "HOUSES must be 0–16 (got: $HOUSES)"
HOUSES=$((10#$HOUSES))
HOUSES_DIR="$HERE/.generated/$TENANT_NAME"
HOUSES_COMPOSE_FILE="$HOUSES_DIR/houses.compose.yml"
HOUSES_POOL_FILE="$HOUSES_DIR/houses.json"
HOUSES_JOURNAL_FILE="$HOUSES_DIR/house-reconcile-state.json"
HOUSES_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bawthub-houses.XXXXXX")"
trap 'rm -rf "$HOUSES_SCRATCH"' EXIT
DESIRED_HOUSES_COMPOSE_FILE="$HOUSES_SCRATCH/houses.compose.yml"
DESIRED_HOUSES_POOL_FILE="$HOUSES_SCRATCH/houses.json"
host_memory_mib() { # REPLY = the Docker host's memory in MiB, or empty if unknown
  local bytes meminfo="${BOOTSTRAP_MEMINFO:-/proc/meminfo}" # override: tests only
  # On Linux the Docker host is this host; elsewhere (Docker Desktop) ask Docker.
  if [[ -r "$meminfo" ]]; then
    bytes=$(( $(awk '/^MemTotal:/ {print $2}' "$meminfo") * 1024 ))
  else
    bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null)" || bytes=""
  fi
  REPLY=""
  # An if, not a bare &&: an unknown reading must not trip errexit.
  if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
    REPLY=$(( bytes / 1048576 ))
  fi
}
house_memory_default() { # each house: half the Docker host's memory, 2–4 GiB
  # A cap is a ceiling, not a reservation: it stops one house starving the
  # tenant. A bot plus a BawtHub preview (Vite's first dependency bundle)
  # peaks near 3 GB, so the cap is not split across the houses.
  local mib
  host_memory_mib
  [[ -n "$REPLY" ]] || { REPLY=3072m; return; }
  mib=$(( REPLY / 2 ))
  (( mib < 2048 )) && mib=2048
  (( mib > 4096 )) && mib=4096
  REPLY="${mib}m"
}
# Each house starts its occupant's preview by itself (TASK-2135). The idle
# stack already uses about 3 GB and a preview's first Vite bundle about 3 GB
# more, so on a smaller host an automatic preview runs the whole tenant out of
# memory. HOUSE_PREVIEW=auto (default) turns it on from 6 GiB of host memory.
HOUSE_PREVIEW_MIN_MIB=6144
house_preview_mode() { # REPLY = on|off; resolved once per run
  if [[ -n "${HOUSE_PREVIEW_RESOLVED:-}" ]]; then REPLY="$HOUSE_PREVIEW_RESOLVED"; return; fi
  house_preview_resolve; HOUSE_PREVIEW_RESOLVED="$REPLY"
}
house_preview_resolve() {
  case "${HOUSE_PREVIEW:-auto}" in
    on|off) REPLY="$HOUSE_PREVIEW" ;;
    auto)
      host_memory_mib
      if [[ -n "$REPLY" ]] && (( REPLY < HOUSE_PREVIEW_MIN_MIB )); then
        log "houses: previews off, host has ${REPLY} MiB (< ${HOUSE_PREVIEW_MIN_MIB}; set HOUSE_PREVIEW=on to force)"
        REPLY=off
      else
        REPLY=on
      fi ;;
    *) die "HOUSE_PREVIEW must be auto, on or off (got: $HOUSE_PREVIEW)" ;;
  esac
}
# The app's own origin rule (llm-bawt agent_bridge.house_pool._origin), checked
# here so a pool the app would refuse fails the install, not silently at
# runtime: bare lowercase http(s), RFC hostname, port 1–65535 written without
# leading zeros, default port omitted. REPLY = host[:port], for duplicates.
house_origin_ok() {
  local label o_scheme o_host o_port labels
  [[ "$1" =~ ^(https?)://([a-z0-9.-]{1,253})(:([1-9][0-9]{0,4}))?$ ]] || return 1
  o_scheme="${BASH_REMATCH[1]}"; o_host="${BASH_REMATCH[2]}"; o_port="${BASH_REMATCH[4]}"
  if [[ -n "$o_port" ]]; then
    (( o_port <= 65535 )) || return 1
    [[ "$o_scheme:$o_port" != "http:80" && "$o_scheme:$o_port" != "https:443" ]] || return 1
  fi
  [[ "$o_host" != .* && "$o_host" != *. && "$o_host" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$o_host"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  REPLY="$o_host${o_port:+:$o_port}"
}
render_houses() {
  local scheme host port base template i id origin hport mem tmp_c tmp_p sep="" seen=""
  local port_slot='{port}' id_slot='{id}'
  [[ "$AGENT_ORIGIN" =~ ^(https?)://([A-Za-z0-9.-]+)(:[0-9]{1,5})?/?$ ]] || \
    die "AGENT_ORIGIN must be a bare http(s) origin to derive house preview origins (got: $AGENT_ORIGIN)"
  scheme="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2],,}"
  base="${HOUSE_PREVIEW_PORT_BASE:-3101}"
  [[ "$base" =~ ^[0-9]{1,5}$ ]] && (( 10#$base >= 1024 && 10#$base + HOUSES - 1 <= 65535 )) || \
    die "HOUSE_PREVIEW_PORT_BASE must leave room for $HOUSES ports in 1024–65535"
  base=$((10#$base))
  # An operator with a TLS proxy can name each preview, e.g.
  # https://{id}.preview.example.com, and forward it to the house's {port}.
  template="${HOUSE_PREVIEW_ORIGIN_TEMPLATE:-}"
  [[ -n "$template" ]] || template="${scheme}://${host}:${port_slot}"
  if [[ -n "${HOUSE_MEMORY:-}" ]]; then
    [[ "$HOUSE_MEMORY" =~ ^[1-9][0-9]*[mMgG]$ ]] || die "HOUSE_MEMORY must be like 3g or 2560m (got: $HOUSE_MEMORY)"
    mem="$HOUSE_MEMORY"
  else
    house_memory_default; mem="$REPLY"
  fi
  local preview
  house_preview_mode; preview="$REPLY"
  local tools_env=""
  if [[ "$AGENT_TOOLS" == "1" ]]; then
    tools_env=$'\n      - CRAWL4AI_API_TOKEN_FILE=/run/bridge-tokens/crawl4ai'
  fi
  tmp_c="$DESIRED_HOUSES_COMPOSE_FILE"
  tmp_p="$DESIRED_HOUSES_POOL_FILE"
  {
    echo "# Generated by deploy/bootstrap.sh from HOUSES=$HOUSES; do not edit (re-run bootstrap)."
    echo "services:"
    echo "  app:"
    echo "    environment:"
    # Always mount the canonical directory, even for zero houses. Never bind
    # disposable scratch; zero is a configured empty pool, not unconfigured.
    echo "      - BAWT_HOUSE_POOL_FILE=/run/llm-bawt-house-pool/houses.json"
    # House previews run Hono as the bridge user (gid 1000), not the frontend's
    # uid, so the service token is also exported 0640 to that group.
    echo "      - BAWTHUB_SERVICE_TOKEN_EXPORT_GID=1000"
    echo "    volumes:"
    echo "      - \"$HOUSES_DIR:/run/llm-bawt-house-pool:ro\""
  } > "$tmp_c"
  printf '{"houses": [' > "$tmp_p"
  for ((i = 1; i <= HOUSES; i++)); do
    id="h$i"; hport=$((base + i - 1))
    for port in "${FRONTEND_PORT:-3000}" "${SERVICE_PORT:-8642}" "${MCP_PORT:-8001}"; do
      (( 10#$port != hport )) || die "house $id preview port $hport collides with a tenant service port"
    done
    origin="${template//"$port_slot"/$hport}"; origin="${origin//"$id_slot"/$id}"
    house_origin_ok "$origin" || \
      die "house $id preview origin must be a bare lowercase http(s) origin, default port omitted (got: $origin)"
    [[ " $seen " != *" ${REPLY} "* ]] || \
      die "house $id preview origin $origin repeats another house's; use {id} or {port} in HOUSE_PREVIEW_ORIGIN_TEMPLATE"
    seen+=" $REPLY"
    printf '%s{"id": "%s", "harness": "claude-code", "origin": "%s", "memory": "%s"}' \
      "$sep" "$id" "$origin" "$mem" >> "$tmp_p"
    sep=", "
    cat >> "$tmp_c" <<EOF
  house-$id:
    image: \${AGENT_BRIDGE_IMAGE_REF}
    container_name: \${TENANT_NAME:-bawthub}-house-$id
    dns_search: ["."]
    command: ["python", "-m", "claude_code_bridge"]
    init: true
    mem_limit: $mem
    # Read-only root: a restart empties every container-local write (TASK-2080).
    # Scratch is owned by the published image's bridge user (uid/gid 1000).
    read_only: true
    tmpfs:
      - /tmp:size=512m,mode=1777
      - /home/bridge/.cache:size=512m,uid=1000,gid=1000,mode=0755
      - /home/bridge/.config:size=16m,uid=1000,gid=1000,mode=0700
      - /home/bridge/.codex:size=64m,uid=1000,gid=1000,mode=0755
      - /home/bridge/.npm:size=256m,uid=1000,gid=1000,mode=0755
    environment:
      - BAWT_HOUSE=$id
      - LLM_BAWT_API_URL=http://app:8642
      - LLM_BAWT_SERVICE_HOST=app
      - REDIS_URL=\${REDIS_URL:-redis://redis:6379/0}
      - CLAUDE_CODE_BAWTHUB_MCP_URL=http://app:8001/mcp
      - BRIDGE_CLAUDE_TOKEN_SECRET=\${BRIDGE_CLAUDE_TOKEN_SECRET:-}
      - ENABLE_TOOL_SEARCH=true
      - CLAUDE_CODE_SKILLS_PATH=/opt/bawthub/skills
      - SKILL_SOURCES_CURRENT=/var/lib/bawthub/skill-sources/current$tools_env
      - GIT_CONFIG_COUNT=3
      - GIT_CONFIG_KEY_0=credential.https://github.com.helper
      - GIT_CONFIG_VALUE_0=bawthub
      - GIT_CONFIG_KEY_1=credential.https://github.com.useHttpPath
      - GIT_CONFIG_VALUE_1=true
      - GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf
      - "GIT_CONFIG_VALUE_2=git@github.com:"
      - BRIDGE_GIT_CREDENTIAL_TOKEN_FILE=/run/bridge-tokens/git-credential
      # pnpm's default home (~/.local/share/pnpm) is on the read-only root.
      # Keep its store on the persistent dev volume, where node_modules lives,
      # so installs hardlink and survive a restart.
      - PNPM_HOME=/home/bridge/.cache/pnpm
      - npm_config_store_dir=/home/bridge/dev/.pnpm-store
      # Preview frontend: the house itself serves its occupant's newest
      # BawtHub task worktree (or a no-preview page) and brings it back after
      # a restart (TASK-2135). Tenants keep sign-in sessions on, bound to this
      # house's own origin, with the tenant's frontend DB and service token.
      - BAWT_HOUSE_PREVIEW=$preview
      - BAWT_HOUSE_PREVIEW_GATE=$BAWT_HOUSE_PREVIEW_GATE
      - BAWTHUB_LLM_URL=http://app:8642
      - TENANT_NAME=\${TENANT_NAME:-bawthub}
      - DATABASE_URL=\${FRONTEND_DATABASE_URL}
      - AGENT_ORIGIN=$origin
      - BAWTHUB_AUTH_SESSIONS=on
      - BAWTHUB_AUTH_URL=$origin
      - BAWTHUB_SERVICE_TOKEN_FILE=/run/bawthub-service-token/token
      # The bridge's llm-bawt API key (TASK-2380); a house is a bridge caller.
      - LLM_BAWT_API_KEY_FILE=/run/llm-bawt-api-key/api-key
    volumes:
      - bridge-claude:/home/bridge/.claude
      - bridge-dev:/home/bridge/dev
      - service-token:/run/bawthub-service-token:ro
      - api-key-bridge:/run/llm-bawt-api-key:ro
      - bridge-tokens:/run/bridge-tokens:ro
      - skill-sources:/var/lib/bawthub/skill-sources:ro
EOF
    if [[ "$MODE" == "dev" ]]; then
      cat >> "$tmp_c" <<EOF
      - \${DEV_SOURCE_DIR}/src:/app/src
      - \${DEV_SOURCE_DIR}/pyproject.toml:/app/pyproject.toml:ro
      - \${DEV_SOURCE_DIR}/README.md:/app/README.md:ro
      - \${DEV_SOURCE_DIR}/LICENSE:/app/LICENSE:ro
      - \${BRIDGE_SSH_KEY_DIR}:/home/bridge/.ssh:ro
EOF
    else
      # The agent bridge's host-access identity and trust (TASK-2520).
      cat >> "$tmp_c" <<EOF
      - bridge-ssh:/home/bridge/.ssh
EOF
    fi
    cat >> "$tmp_c" <<EOF
    ports:
      - "$hport:5173"
    depends_on:
      redis:
        condition: service_healthy
      # Healthy, not just started: the house writes its MCP settings (the
      # Crawl4AI bearer the app exports at startup) once at boot.
      app:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8681/health"]
      interval: 15s
      timeout: 5s
      retries: 3
    restart: unless-stopped
EOF
  done
  printf ']}\n' >> "$tmp_p"
  chmod 0644 "$tmp_p" "$tmp_c"
}
render_houses

# ── 2. Compute the -f file list from the composition matrix ────────────────
FILES=("-f" "$COMPOSE_DIR/docker-compose.base.yml")
if [[ "$EXTERNAL_DB" == "1" ]]; then
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.external-postgres.yml")
  log "postgres: EXTERNAL ($EXTERNAL_POSTGRES_HOST) — local pgvector dropped"
else
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.localdb.yml")
  log "postgres: LOCAL (in-stack pgvector)"
fi
if [[ -n "${EMBED_IMAGE:-}" ]]; then
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.embeddings.yml")
  log "embeddings: LOCAL CPU sidecar ($EMBED_IMAGE)"
else
  log "embeddings: none — memory degrades to non-vector search (set EMBED_IMAGE to enable vector search)"
fi
case "$VOICE" in
  pocket)
    FILES+=("-f" "$COMPOSE_DIR/docker-compose.voice.yml")
    if [[ -n "${CPU_STT_IMAGE_REF:-}" ]]; then
      FILES+=("-f" "$COMPOSE_DIR/docker-compose.cpu-stt.yml")
      log "voice: local CPU Pocket preset + Vosk English microphone input"
    else
      log "voice: local CPU Pocket preset (text-in / voice-out; add CPU_STT_IMAGE_REF for microphone input)"
    fi
    ;;
  external)
    FILES+=("-f" "$COMPOSE_DIR/docker-compose.external-voice.yml")
    log "voice: external backend (no local TTS/STT)"
    ;;
  off) log "voice: disabled" ;;
esac
if [[ -n "${LLM_BAWT_PEER_PORT:-}" ]]; then
  [[ "${LLM_BAWT_PEER_PUBLIC_URL:-}" == https://* ]] || \
    die "LLM_BAWT_PEER_PORT needs LLM_BAWT_PEER_PUBLIC_URL=https://<lan-address>:$LLM_BAWT_PEER_PORT"
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.peer.yml")
  log "peers: HTTPS listener on ${LLM_BAWT_PEER_BIND_IP:-?}:$LLM_BAWT_PEER_PORT ($LLM_BAWT_PEER_PUBLIC_URL)"
else
  log "peers: off (set LLM_BAWT_PEER_PORT to pair with other installs)"
fi
if [[ "$TENANT_OPS" == "1" ]]; then
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.ops.yml")
else
  log "ops: disabled (TENANT_OPS=0) — no ops runner, no Docker socket mount"
fi

# TENANT_OPS=0 on a rerun: Compose does not remove a service that left the
# file list, so stop and remove this project's own ops-reconciler (matched by
# project + service labels, nothing else). Its job workers are --rm and
# finish or die with it; the app's admissions then fail closed (unreachable).
remove_ops_runner() {
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$TENANT_NAME" \
    --filter "label=com.docker.compose.service=ops-reconciler")"
  [[ -n "$ids" ]] || return 0
  log "ops: TENANT_OPS=0 — removing this project's ops-reconciler"
  # shellcheck disable=SC2086
  docker stop --time 30 $ids >/dev/null && docker rm $ids >/dev/null || \
    die "could not remove the ops-reconciler ($ids); stop it by hand and rerun"
}
if [[ "$AGENT_TOOLS" == "1" ]]; then
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.agent-tools.yml")
  log "agent tools: Playwright MCP + Crawl4AI (CPU)"
else
  log "agent tools: disabled (AGENT_TOOLS=0) — no browser or crawl MCP"
fi
# AGENT_TOOLS=0 on a rerun: remove this project's two tool containers, which
# Compose leaves behind once their overlay leaves the file list.
remove_agent_tools() {
  local ids
  ids="$(for svc in playwright-mcp crawl4ai; do
    docker ps -aq --filter "label=com.docker.compose.project=$TENANT_NAME" \
      --filter "label=com.docker.compose.service=$svc"; done)"
  [[ -n "$ids" ]] || return 0
  log "agent tools: AGENT_TOOLS=0 — removing this project's playwright-mcp and crawl4ai"
  # shellcheck disable=SC2086
  docker rm -f $ids >/dev/null || die "could not remove the agent tool containers ($ids); remove them by hand and rerun"
}
if [[ "$MODE" == "dev" ]]; then
  FILES+=("-f" "$COMPOSE_DIR/docker-compose.dev.yml")
  [[ "$DEV_FRONTEND" != "1" ]] || FILES+=("-f" "$COMPOSE_DIR/docker-compose.dev-frontend.yml")
fi
# Dev frontend only: bring the node_modules volume up to the checkout's
# dependency inputs, then run "$@" in a one-shot frontend container. The
# running dev server is stopped first so two installs never share the volume.
dev_frontend_sync() {
  compose stop frontend >/dev/null 2>&1 || true
  compose run --rm --no-deps -T --entrypoint sh frontend scripts/dev-deps-sync.sh "$@"
}
# Published overlay is always last in the shared driver's Compose command.
# Bootstrap itself uses the candidate, including on a brand-new tenant.
PUBLISHED_FILES=("${FILES[@]}" "-f" "$HOUSES_COMPOSE_FILE")
FILES+=("-f" "$DESIRED_HOUSES_COMPOSE_FILE")
log "houses: $HOUSES (pool $HOUSES_POOL_FILE)"
log "MODE=$MODE TENANT_NAME=$TENANT_NAME VOICE=$VOICE files:${FILES[*]//-f /}"

compose() { docker compose --project-name "$TENANT_NAME" "${FILES[@]}" "$@"; }

# Published images without a registry login (release bundles). Each pinned
# ghcr.io/bawthub/<name>@sha256:<digest> keeps its manifest pin; only for this
# run it may resolve to the same name and digest on a loopback registry the
# installer serves from the bundle. Docker verifies the content against the
# digest, so the image is the published one byte for byte. Order per image:
#   1. the ghcr.io reference is already on this Docker host: use it;
#   2. the identical loopback copy is already here (an earlier bundle run): use it;
#   3. BAWTHUB_IMAGE_MIRROR=127.0.0.1:<port> is set: pull from it, then use it;
#   4. otherwise leave the ghcr.io reference for the normal pull.
# Only the exported variables for this process change; tenant.env does not.
# IMAGES_LOCAL_ONLY=1 afterwards means every resolved image is local, so the
# pull fetches only what is missing (third-party tags included).
IMAGES_LOCAL_ONLY=0
MIRROR_RE='^(127\.0\.0\.1|localhost):[0-9]{1,5}$'
loopback_copy() { # $1=name $2=digest → REPLY = a local loopback ref with that digest
  local repo digest
  REPLY=""
  while read -r repo digest; do
    if [[ "$digest" == "$2" && "$repo" =~ ^(127\.0\.0\.1|localhost):[0-9]{1,5}/bawthub/$1$ ]]; then
      REPLY="$repo@$digest"
      return 0
    fi
  done < <(docker image ls --digests --format '{{.Repository}} {{.Digest}}' 2>/dev/null)
  return 1
}
resolve_published_images() {
  local images ref name digest key i resolved=0 missing_any=0
  local from=() to=()   # parallel arrays: Bash 3.2 (macOS) has no associative arrays
  [[ -z "$IMAGE_MIRROR" || "$IMAGE_MIRROR" =~ $MIRROR_RE ]] || \
    die "BAWTHUB_IMAGE_MIRROR must be 127.0.0.1:<port> or localhost:<port> (got: $IMAGE_MIRROR)"
  images="$(compose config --images 2>/dev/null)" || die "could not list the images this install uses"
  [[ "$TENANT_OPS" != "1" ]] || images+=$'\n'"$OPS_WORKER_IMAGE_REF"
  while IFS= read -r ref; do
    [[ "$ref" =~ ^ghcr\.io/bawthub/([a-z0-9._-]+)@(sha256:[0-9a-f]{64})$ ]] || continue
    name="${BASH_REMATCH[1]}" digest="${BASH_REMATCH[2]}"
    for i in ${from[@]+"${!from[@]}"}; do [[ "${from[$i]}" != "$ref" ]] || continue 2; done
    REPLY=""
    if docker image inspect "$ref" >/dev/null 2>&1; then
      REPLY="$ref"
    elif ! loopback_copy "$name" "$digest" && [[ -n "$IMAGE_MIRROR" ]]; then
      log "loading $name@${digest:7:12} from the release bundle…"
      docker pull -q "$IMAGE_MIRROR/bawthub/$name@$digest" >/dev/null || \
        die "the release bundle does not provide $ref (nothing started from it)"
      loopback_copy "$name" "$digest" || REPLY="$IMAGE_MIRROR/bawthub/$name@$digest"
    fi
    if [[ -z "$REPLY" ]]; then missing_any=1; REPLY="$ref"; fi
    [[ "$REPLY" == "$ref" ]] || resolved=1
    from+=("$ref"); to+=("$REPLY")
  done <<< "$images"
  (( resolved )) || [[ -n "$IMAGE_MIRROR" ]] || return 0
  for key in APP_IMAGE_REF TENANT_FRONTEND_IMAGE_REF AGENT_BRIDGE_IMAGE_REF OPS_WORKER_IMAGE_REF \
             EMBED_IMAGE POCKET_IMAGE_REF VOICE_BACKEND_IMAGE_REF CPU_STT_IMAGE_REF; do
    ref="${!key:-}"
    for i in ${from[@]+"${!from[@]}"}; do
      [[ -n "$ref" && "${from[$i]}" == "$ref" && "${to[$i]}" != "$ref" ]] || continue
      printf -v "$key" '%s' "${to[$i]}"
      export "${key?}"
      log "image: $key uses ${to[$i]} (pin unchanged: $ref)"
    done
  done
  (( missing_any )) || IMAGES_LOCAL_ONLY=1
}

# Warn about secret values written into the manifest (provider keys belong in
# the app's encrypted store). The app image's checker reads the manifest on
# stdin and prints only file:line, the setting name and a finding code.
tenant_env_secret_check() {
  local out rc=0
  # shellcheck disable=SC2016
  out="$(compose run --rm --no-deps -T app python -c '
import sys
try:
    from llm_bawt.secret_guard import scan_env_text
except ImportError:
    sys.exit(3)
for finding in scan_env_text(sys.stdin.read(), "tenant.env"):
    print(finding)
' < "$MANIFEST" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    3) log "manifest secret check: skipped (this app image has no llm_bawt.secret_guard)"; return 0 ;;
    *) log "WARNING manifest secret check could not run (exit $rc)"; return 0 ;;
  esac
  [[ -n "$out" ]] || return 0
  log "WARNING secret values in $MANIFEST (names only). Connect providers in the app, or move these into the tenant secrets directory, then remove them from the manifest:"
  while IFS= read -r line; do
    [[ -z "$line" ]] || log "  $line"
  done <<< "$out"
}

# step TEXT: a progress marker the installer shows; every other line is detail.
step() { log "@step $*"; }

# After an install starts, show where to go. Final markers for the installer
# (TASK-2507): @access <mode>, @ready <url>, then, while owner setup is
# unfinished, @setup-code-file <path>. The code itself is never logged.
announce_setup() {
  local state=""
  log "@access $ACCESS"
  # The frontend's effective session setting (compose defaults it to off).
  log "@sessions ${BAWTHUB_AUTH_SESSIONS:-off}"
  if [[ "$ACCESS" != "signin" ]]; then
    # A retained session override binds sign-in to its configured origin.
    if [[ "${BAWTHUB_AUTH_SESSIONS:-off}" != off && -n "${BAWTHUB_AUTH_URL:-}" ]]; then
      log "@ready ${BAWTHUB_AUTH_URL%/}"
      return 0
    fi
    log "@ready http://localhost:${FRONTEND_PORT:-3000}"
    return 0
  fi
  log "@ready $BAWTHUB_AUTH_URL"
  state="$(curl -fsS --max-time 5 "http://localhost:${FRONTEND_PORT:-3000}/api/setup/owner" 2>/dev/null | \
    sed -n -E 's/.*"state":"([a-z]+)".*/\1/p')" || state=""
  [[ "$state" != "done" ]] || return 0
  # A frontend image older than the installer-held code ignores it and logs
  # its own; fall back to reading that one.
  local frontend_log
  frontend_log="$(compose logs --no-color --no-log-prefix frontend 2>/dev/null)" || frontend_log=""
  if [[ -n "${BAWTHUB_OWNER_SETUP_CODE:-}" && "$frontend_log" == *"BAWTHUB_OWNER_SETUP_CODE"* ]]; then
    log "sign-in: open $BAWTHUB_AUTH_URL/setup to create the owner account; the one-time code is in $OWNER_SETUP_CODE_FILE"
    log "@setup-code-file $OWNER_SETUP_CODE_FILE"
    return 0
  fi
  local code
  code="$(printf '%s\n' "$frontend_log" | sed -n -E 's/^.*(New setup code|Setup code): ([^[:space:]]+).*$/\2/p' | tail -n 1)" || code=""
  if [[ -n "$code" ]]; then
    log "sign-in: open $BAWTHUB_AUTH_URL/setup and enter setup code $code to create the owner account (it works once)"
  else
    log "sign-in: open $BAWTHUB_AUTH_URL/setup (no setup code found; reset a lost owner setup with the frontend's setup:reset script)"
  fi
}
reconcile_houses() {
  local settings="$HOUSES_SCRATCH/settings.json"
  # With previews off nothing listens on a house's preview port, so the
  # reconciler checks health and lease only.
  local preview
  house_preview_mode; preview="$REPLY"
  python3 - "$settings" "$TENANT_NAME" "$HOUSES_COMPOSE_FILE" \
    "$DESIRED_HOUSES_COMPOSE_FILE" "$HOUSES_POOL_FILE" \
    "$DESIRED_HOUSES_POOL_FILE" "$HOUSES_JOURNAL_FILE" "$preview" \
    docker compose --project-name "$TENANT_NAME" "${PUBLISHED_FILES[@]}" <<'PY'
import json
import sys

path, project, compose_file, desired_compose, pool, desired_pool, journal, preview, *command = sys.argv[1:]
with open(path, "w") as out:
    json.dump(dict(project=project, layout="rendered", compose_command=command,
                   compose_file=compose_file, desired_compose_file=desired_compose,
                   pool_file=pool, desired_pool_file=desired_pool,
                   journal_file=journal, preview_probe=preview == "on"), out)
PY
  HOUSES="$HOUSES" python3 "$HERE/house_reconcile_host.py" --settings "$settings" "$@"
}

# ── 3-6. Act ───────────────────────────────────────────────────────────────
case "$ACTION" in
  houses)
    [[ $# == 1 || ( $# == 2 && "$2" == "--apply" ) ]] || die "use: houses [--apply]"
    reconcile_houses "${@:2}"
    ;;
  config)
    compose config "${@:2}"
    ;;
  down)
    # Use the published inventory when available, not an unapplied count edit.
    [[ ! -f "$HOUSES_COMPOSE_FILE" ]] || FILES=("${PUBLISHED_FILES[@]}")
    services="$(compose config --services)" || die "could not list services"
    down_services=()
    while IFS= read -r service; do
      [[ -z "$service" ]] || down_services+=("$service")
    done <<< "$services"
    (( ${#down_services[@]} > 0 )) || die "no services in merged config"
    compose stop "${down_services[@]}"
    compose rm -f "${down_services[@]}"
    ;;
  up)
    [[ ! -f "$BAWTHUB_MASTER_KEY_FILE" ]] || \
      log "legacy vault master key found at $BAWTHUB_MASTER_KEY_FILE; run ./bootstrap.sh import-vault to move its provider keys into the encrypted store"
    step "Checking your settings"
    log "validating merged config…"
    compose config >/dev/null || die "compose config failed — see error above"
    # Record the access choice so a later rerun keeps it without ACCESS set.
    [[ -f "$ACCESS_FILE" && "$(< "$ACCESS_FILE")" == "$ACCESS" ]] || store_secret "$ACCESS" "$ACCESS_FILE"
    if [[ "${POSTGRES_PASSWORD_GENERATED:-0}" == "1" ]]; then
      store_secret "$LLM_BAWT_POSTGRES_PASSWORD" "$LLM_BAWT_POSTGRES_PASSWORD_FILE"
      log "local DB password: GENERATED → $LLM_BAWT_POSTGRES_PASSWORD_FILE (0600). Back it up with the database."
    fi
    provision_bridge_ssh
    if [[ "$IMAGE_SOURCE" == "local" ]]; then
      for ref in "$APP_IMAGE_REF" "$TENANT_FRONTEND_IMAGE_REF" "$AGENT_BRIDGE_IMAGE_REF" "${EMBED_IMAGE:-}"; do
        [[ "$ref" == localhost/* ]] || continue
        docker image inspect "$ref" >/dev/null 2>&1 || \
          die "local image $ref is not on this Docker host (run deploy/build-local.sh here first)"
      done
      log "pulling published images (local builds are already present)…"
      compose pull --policy missing
    elif [[ "$MODE" == "prod" ]]; then
      step "Downloading BawtHub (a few GB the first time; this can take a while)"
      resolve_published_images
      log "pulling images…"
      if (( IMAGES_LOCAL_ONLY )); then compose pull --policy missing; else compose pull; fi
    fi
    if [[ "$TENANT_OPS" == "1" && "$OPS_WORKER_IMAGE_REF" == ghcr.io/* ]]; then
      docker image inspect "$OPS_WORKER_IMAGE_REF" >/dev/null 2>&1 || docker pull -q "$OPS_WORKER_IMAGE_REF" >/dev/null || \
        die "cannot pull OPS_WORKER_IMAGE_REF=$OPS_WORKER_IMAGE_REF"
    elif [[ "$TENANT_OPS" == "1" ]]; then
      docker image inspect "$OPS_WORKER_IMAGE_REF" >/dev/null 2>&1 || \
        die "local ops worker image $OPS_WORKER_IMAGE_REF is not on this Docker host"
    fi
    [[ "$TENANT_OPS" == "1" ]] || remove_ops_runner
    [[ "$AGENT_TOOLS" == "1" ]] || remove_agent_tools
    # Every `compose run app` bind-mounts the house pool directory. Create it
    # as this user first, or Docker creates it root-owned on a fresh install
    # and the pool file below can't be written.
    mkdir -p "$HOUSES_DIR"
    tenant_env_secret_check
    # Needs the app image (it reads the app-config volume) and must run before
    # the app first starts with these values.
    provision_app_secret_key
    provision_bridge_token_secret
    if [[ "$MODE" == "dev" ]]; then
      # A fresh dev venv starts with the pinned image's dependencies. Reconcile
      # the worktree lock before starting either process; subsequent code-only
      # pushes use compose restart and never reinstall anything.
      compose run --rm --no-deps -T --entrypoint uv app \
        sync --locked --no-dev --extra mcp --extra service --extra search || \
        die "dev app dependency sync failed"
      # The bridge image already installed llm-bawt editable against /app/src.
      # Its source bind mount takes effect without rebuilding or reinstalling.
    fi
    # The app must not start against an old shared database. Provision and
    # migrate first, using the image's committed migration baseline. No schema
    # push, and no host Node/Postgres installation required.
    if [[ "$EXTERNAL_DB" != "1" ]]; then
      step "Starting the database"
      log "starting local PostgreSQL…"
      compose up -d --wait postgres || die "local PostgreSQL did not become healthy"
    fi
    app_db_env
    if [[ "$DEV_FRONTEND" == "1" ]]; then
      log "dev frontend: building from $DEV_FRONTEND_SOURCE_DIR and syncing its dependencies…"
      dev_frontend_sync true || die "dev frontend dependency sync failed (no app/frontend started)"
    fi
    log "checking database isolation before app startup…"
    compose run --rm --no-deps --entrypoint node \
      -e DB_APP_HOST -e DB_APP_PORT -e DB_APP_USER -e DB_APP_PASSWORD \
      -e DB_APP_DATABASE -e DB_INIT_CREATE \
      frontend scripts/tenant-db-init.mjs || die "database preflight failed (no app/frontend started)"
    step "Preparing the database"
    log "deploying frontend migrations…"
    compose run --rm --no-deps --entrypoint /app/node_modules/.bin/prisma \
      frontend migrate deploy || die "frontend migration failed (no app/frontend started)"
    # The runtime reconciliation CLI lives in the app. A fresh app must first
    # see an empty advertised pool, never houses that are not healthy yet.
    mkdir -p "$HOUSES_DIR"
    if [[ ! -e "$HOUSES_POOL_FILE" ]]; then
      (set -o noclobber; printf '{"houses":[]}\n' > "$HOUSES_POOL_FILE") || \
        die "could not initialize the advertised house pool"
      chmod 0644 "$HOUSES_POOL_FILE"
    fi
    services="$(compose config --services)" || die "could not list core services"
    core_services=()
    while IFS= read -r service; do
      [[ -z "$service" || "$service" =~ ^house-h[1-9][0-9]*$ ]] || core_services+=("$service")
    done <<< "$services"
    (( ${#core_services[@]} > 0 )) || die "no core services in merged config"
    step "Starting BawtHub (this can take a few minutes)"
    log "starting named core services and waiting for health…"
    compose up -d --wait "${core_services[@]}" || die "core services did not become healthy"
    reconcile_houses --apply || die "house reconciliation failed; inspect its plan and journal"
    if [[ "$VOICE" == "pocket" ]]; then
      step "Setting up voices"
      log "waiting for the published preset and seeding the tenant voice catalog…"
      seeded=0
      for _ in $(seq 1 120); do
        if compose exec -T voice-backend /app/.venv/bin/python -m bawthub.tts.seed_pocket_preset >/dev/null 2>&1; then
          seeded=1; break
        fi
        sleep 5
      done
      [[ "$seeded" == "1" ]] || die "Pocket preset/model/catalog seeding failed; inspect voice-backend and pocket-tts logs"
    fi
    if [[ "$TENANT_OPS" == "1" ]]; then
      # Point the seeded (disabled) restart actions at this project's own
      # containers and enable them behind approval cards. Idempotent: rows
      # already classified or edited by an operator are left alone. The app
      # seeds the catalog at startup, so retry until it is there.
      log "classifying the ops catalog for this install…"
      svc_map="$(compose ps --format '{{.Service}} {{.Name}}' | \
        awk 'BEGIN{printf "{"} {printf "%s\"%s\":\"%s\"", (NR>1?",":""), $1, $2} END{print "}"}')"
      classified=0
      for _ in $(seq 1 30); do
        if out="$(printf '%s' "$svc_map" | compose exec -T app python -m llm_bawt.ops.tenant_catalog --project "$TENANT_NAME" 2>&1)"; then
          classified=1; break
        fi
        sleep 5
      done
      if [[ "$classified" == "1" ]]; then log "ops catalog: $out"
      else log "WARNING ops catalog not classified (restart actions stay disabled): $out"; fi
    fi
    # The long-lived voice backend caches DB snapshots for up to 60s and the
    # seeder runs in a separate process, so verify retries the voice probe
    # within its readiness deadline instead of failing on the first attempt.
    step "Checking everything works"
    "$0" verify
    announce_setup
    ;;
  dev-reload)
    [[ "$MODE" == "dev" ]] || die "dev-reload requires MODE=dev"
    [[ $# -le 1 ]] || die "dev-reload takes no options (set DEV_DEPS_CHANGED=1 when uv.lock changed, DEV_FRONTEND_CHANGED=1 when frontend dependencies, schema or migrations changed)"
    [[ "${DEV_FRONTEND_CHANGED:-0}" == "0" || "${DEV_FRONTEND_CHANGED:-0}" == "1" ]] || \
      die "DEV_FRONTEND_CHANGED must be 0 or 1"
    [[ "${DEV_RELOAD_PYTHON:-1}" == "0" || "${DEV_RELOAD_PYTHON:-1}" == "1" ]] || \
      die "DEV_RELOAD_PYTHON must be 0 or 1"
    if [[ "$DEV_FRONTEND" == "1" ]]; then
      # Code edits reach the browser through HMR and Hono's tsx watch with no
      # restart. Dependency, Prisma schema/migration or Dockerfile changes:
      # rebuild, sync node_modules and migrate before the dev server restarts.
      if [[ "${DEV_FRONTEND_CHANGED:-0}" == "1" ]] || ! compose ps --status running --services 2>/dev/null | grep -qx frontend; then
        dev_frontend_sync /app/node_modules/.bin/prisma migrate deploy || \
          die "dev frontend dependency sync or migration failed; frontend left stopped"
      fi
      compose up -d --no-deps --wait frontend || die "dev frontend did not become healthy"
    fi
    if [[ "${DEV_DEPS_CHANGED:-0}" == "1" ]]; then
      compose run --rm --no-deps -T --entrypoint uv app \
        sync --locked --no-dev --extra mcp --extra service --extra search || \
        die "dev app dependency sync failed; app not restarted"
    elif [[ "${DEV_DEPS_CHANGED:-0}" != "0" ]]; then
      die "DEV_DEPS_CHANGED must be 0 or 1"
    fi
    # Apply overlay/image changes (notably the bridge's image-owned venv)
    # before restarting the source-mounted processes. An unchanged config is
    # a no-op here; the restart still picks up a code-only worktree push.
    # DEV_RELOAD_PYTHON=0 (a frontend-only push) skips the restart; changed
    # config, such as newly enabling the dev frontend, still recreates them.
    compose up -d --no-deps app agent-bridge
    [[ "${DEV_RELOAD_PYTHON:-1}" == "0" ]] || compose restart app agent-bridge
    "$0" verify
    ;;
  migrate-db)
    # TASK-1127: read-only inventory of an old mixed (app + frontend tables in
    # one DB) or db-push frontend DB, checked against the migrated schema baked
    # into the pinned frontend image. Changes no database contents. The cutover
    # itself is TASK-1289 and is not implemented.
    [[ $# -le 1 ]] || die "migrate-db takes no options: this version only reports (the cutover is TASK-1289)"
    if [[ "$EXTERNAL_DB" != "1" ]]; then
      log "starting local PostgreSQL (if stopped)…"
      compose up -d --wait postgres || die "local PostgreSQL did not become healthy"
      TENANT_DB_MODE=local
    else
      TENANT_DB_MODE=external
    fi
    export TENANT_DB_MODE
    app_db_env
    state_dir="${TENANT_STATE_DIR:-$HOME/.local/share/bawthub/$TENANT_NAME}"
    ( umask 077; mkdir -p "$state_dir" )
    report="$state_dir/migrate-db-inventory-$(date -u +%Y%m%dT%H%M%SZ).json"
    log "inventory ($TENANT_DB_MODE database, read-only) with $TENANT_FRONTEND_IMAGE_REF…"
    if ! ( umask 077; compose run --rm --no-deps -T --entrypoint node \
        -e DB_APP_HOST -e DB_APP_PORT -e DB_APP_USER -e DB_APP_PASSWORD -e DB_APP_DATABASE \
        -e TENANT_DB_MODE -e TENANT_FRONTEND_IMAGE_REF \
        frontend scripts/tenant-db-inventory.mjs >"$report" ); then
      rm -f "$report"
      die "inventory failed; nothing was changed. Frontend images older than migrate-db lack scripts/tenant-db-inventory.mjs: pin a newer TENANT_FRONTEND_IMAGE_REF"
    fi
    [[ -s "$report" ]] || { rm -f "$report"; die "inventory produced no report; nothing was changed"; }
    log "report: $report"
    log "report sha256: $(sha256sum "$report" | cut -d' ' -f1)"
    ;;
  verify)
    log "waiting for app and frontend readiness…"
    app_port="${SERVICE_PORT:-8642}"
    fe_port="${FRONTEND_PORT:-3000}"
    timeout="${VERIFY_TIMEOUT_SECONDS:-180}"
    [[ "$timeout" =~ ^[0-9]{1,4}$ ]] && (( 10#$timeout >= 1 && 10#$timeout <= 3600 )) || \
      die "VERIFY_TIMEOUT_SECONDS must be 1–3600 seconds"
    # The public API inside the frontend container: the image serves it on
    # 3000, the HMR dev frontend's Hono on 3001 (Vite owns the published port).
    fe_api_port=3000
    (( DEV_FRONTEND )) && fe_api_port=3001
    voice_probe() {
      case "$VOICE" in
        pocket)
          # Exercise the SAME browser route and provider adapter used for chat
          # playback; /health alone can be 200 while speech is broken.
          # It proves the service token as a named job: with the picker policy
          # an unnamed caller gets 401 on everything past /providers.
          compose exec -T -e "VERIFY_CPU_STT=${CPU_STT_IMAGE_REF:+1}" -e "FE_API=http://localhost:$fe_api_port" frontend node -e '
            const root = process.env.FE_API + "/api/v1/tts";
            const token = (await import("node:fs")).readFileSync(process.env.BAWTHUB_SERVICE_TOKEN_FILE, "utf8").trim();
            const headers = {"Authorization": "Bearer " + token, "X-Agent-Cron": "bootstrap-verify"};
            if (process.env.VERIFY_CPU_STT === "1") {
              const health = await (await fetch(process.env.FE_API + "/api/v1/health", {headers, signal:AbortSignal.timeout(12000)})).json();
              if (!health.stt_up || !health.realtime_ready) throw Error("CPU microphone input not ready");
            }
            const status = await (await fetch(root + "/providers", {headers, signal: AbortSignal.timeout(12000)})).json();
            const pocket = status.providers.find(p => p.name === "pocket");
            if (status.default_provider !== "pocket" || !pocket?.healthy || !pocket.configured || pocket.voice_count < 1) throw Error("Pocket provider not ready");
            const voices = await (await fetch(root + "/voices?provider=pocket", {headers, signal: AbortSignal.timeout(12000)})).json();
            if (!voices.voices.some(v => v.id === "pocket:alba")) throw Error("Published preset not selectable");
            const audio = await fetch(root + "/preview", {method:"POST", headers:{...headers, "Content-Type":"application/json"}, body:JSON.stringify({voice:"pocket:alba",text:"Hello."}), signal:AbortSignal.timeout(120000)});
            if (!audio.ok || !audio.headers.get("content-type")?.includes("audio/wav") || (await audio.arrayBuffer()).byteLength <= 44) throw Error("Preset speech did not produce a WAV");
          ' >/dev/null 2>&1
          ;;
        external)
          compose exec -T -e "FE_API=http://localhost:$fe_api_port" frontend node -e '
            const r = await fetch(process.env.FE_API + "/api/v1/health", {signal:AbortSignal.timeout(12000)});
            if (!r.ok) throw Error("External voice backend not healthy");
          ' >/dev/null 2>&1
          ;;
        *) return 0 ;;
      esac
    }
    # The first agent needs a live bridge command consumer, not just a running
    # container: the app's setup route pings it and reports ready/detail.
    agent_detail="no answer from /v1/setup/agent-runtime"
    agent_probe() {
      local body
      # Authenticated as BawtHub's service bearer (llm-bawt TASK-2380 refuses
      # anonymous /v1/* once enforced). The token is read from the frontend
      # that holds it and handed to curl on stdin, never in argv.
      local token
      token="$(compose exec -T frontend sh -c 'cat "$BAWTHUB_SERVICE_TOKEN_FILE"' 2>/dev/null | tr -d '[:space:]')"
      body="$(printf 'Authorization: Bearer %s\n' "$token" | \
        curl -fsS --max-time 10 -H @- "http://localhost:${app_port}/v1/setup/agent-runtime" 2>/dev/null)" || return 1
      [[ "$body" =~ \"ready\"[[:space:]]*:[[:space:]]*true ]] && return 0
      [[ "$body" =~ \"detail\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && agent_detail="${BASH_REMATCH[1]}"
      return 1
    }
    # Signin tenants: the modes the running app actually applies. A settings
    # row (e.g. left by an earlier trusted-lan run) beats the env default, so
    # read them from the app. Weaker than enforce fails unless the manifest
    # chose that variable's opt-out, which only warns.
    modes_detail="the app did not report its auth modes"
    modes_probe() {
      local out var effective weak=()
      out="$(compose exec -T app python -c '
from llm_bawt.api_auth import mcp, wiring
from llm_bawt.service.request_guard import GuardPolicy
mcp.ensure_store()
print("LLM_BAWT_API_AUTH_MODE", wiring.RESOLVER.mode())
print("LLM_BAWT_MCP_AUTH_MODE", mcp.RESOLVER.mode())
print("LLM_BAWT_HOST_GUARD", GuardPolicy.from_env().mode)
' 2>/dev/null)" || return 1
      for var in "${ENFORCE_VARS[@]}"; do
        effective="$(sed -n -E "s/^$var ([a-z]+)$/\1/p" <<<"$out")"
        [[ -n "$effective" ]] || return 1
        [[ "$effective" != "enforce" ]] || continue
        if [[ "${!var}" != "enforce" ]]; then
          log "WARNING $var: effective mode $effective (manifest opt-out)"
        else
          weak+=("$var=$effective")
        fi
      done
      (( ${#weak[@]} == 0 )) && return 0
      modes_detail="weaker than enforce without an opt-out: ${weak[*]} (a stored settings row overrides the default; set it to enforce in the app, or set the variable in $MANIFEST to opt out)"
      modes_final=1
      return 1
    }
    # Exposure probe: every port Compose publishes beyond loopback must refuse
    # an anonymous caller with that service's own authentication refusal, for
    # every Host a client could send. Any other answer (200, redirect, 404, a
    # WebSocket 101, no answer) fails, and so does a published port this table
    # doesn't know, unless PROBE_ALLOW_PORTS lists it. Under a manifest
    # opt-out the matching finding only warns.
    exposure_failures=0
    probe_body="$HOUSES_SCRATCH/exposure-probe-body"  # removed with the scratch dir on exit
    probe_finding() { # $1=opted-out(0|1) $2=message
      if [[ "$1" == "1" ]]; then
        log "WARNING exposure: $2 (manifest opt-out)"
      else
        log "exposure : FAIL ($2)"
        exposure_failures=$((exposure_failures + 1))
      fi
    }
    # $1=opt-out $2=label $3=expected status regex $4=body marker (ERE, may be
    # empty) $5=URL, then extra curl arguments.
    probe_refusal() {
      local optout="$1" label="$2" want="$3" marker="$4" url="$5" code
      shift 5
      code="$(curl -s --max-time 5 -o "$probe_body" -w '%{http_code}' "$@" "$url" 2>/dev/null)" || true
      [[ "$code" =~ ^($want)$ ]] && { [[ -z "$marker" ]] || grep -Eq "$marker" "$probe_body"; } && return 0
      probe_finding "$optout" "$label answered ${code:-nothing} without credentials"
    }
    ws_headers=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13'
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')
    fe_upgrade_refusal=401
    [[ "$VOICE" != "off" ]] || fe_upgrade_refusal='401|000'
    # With previews off no house serves its preview port; no answer is safe.
    house_preview_mode
    preview_refusal=401
    [[ "$REPLY" == "on" ]] || preview_refusal='401|000'
    mcp_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bootstrap-probe","version":"1"}}}'
    # This computer's LAN address, never failing under set -e: Linux has
    # `hostname -I`; macOS has neither that option nor a failure-safe default,
    # so it asks the default route's interface. Loopback when neither answers.
    lan_address() {
      local a="" ifc=""
      a="$(hostname -I 2>/dev/null | awk '{print $1}')" || a=""
      if [[ -z "$a" ]] && command -v ipconfig >/dev/null 2>&1; then
        ifc="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')" || ifc=""
        a="$(ipconfig getifaddr "${ifc:-en0}" 2>/dev/null)" || a=""
      fi
      printf '%s' "${a:-127.0.0.1}"
    }
    exposure_probe() {
      local rows svc pubs pub bind port target addr base host hosts seen=" " allowed optout
      rows="$(compose ps --format '{{.Service}}{{range .Publishers}} {{.URL}}|{{.PublishedPort}}|{{.TargetPort}}{{end}}' 2>/dev/null)" || {
        probe_finding 0 "could not list published ports"; return; }
      addr="${PROBE_ADDRESS:-}"
      [[ -n "$addr" ]] || addr="$(lan_address)"
      [[ "$addr" != *:* ]] || addr="[$addr]"
      allowed="${PROBE_ALLOW_PORTS:-}"
      allowed=" ${allowed//,/ } "
      while read -r svc pubs; do
        [[ -n "$svc" ]] || continue
        for pub in $pubs; do
          IFS='|' read -r bind port target <<<"$pub"
          [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )) || continue
          case "$bind" in 127.*|::1|localhost) continue ;; esac
          [[ "$seen" != *" $port "* ]] || continue
          seen+="$port "
          if [[ "$allowed" == *" $port "* ]]; then
            log "WARNING exposure: port $port ($svc) published beyond loopback and not probed (PROBE_ALLOW_PORTS)"
            continue
          fi
          base="http://$addr:$port"
          hosts=("$addr:$port" "localhost:$port" "$svc")
          [[ -z "${BAWTHUB_AUTH_URL:-}" ]] || \
            hosts+=("$(sed -E 's#^https?://(\[[^]]*\]|[^:/]*).*$#\1#' <<<"$BAWTHUB_AUTH_URL")")
          case "$svc:$target" in
            frontend:3000|frontend:5173) [[ "$ACCESS" == "signin" ]] ;;  # 5173: dev HMR frontend
            app:8642) [[ "$ACCESS" == "signin" && "${LLM_BAWT_API_AUTH_MODE:-}" == "enforce" ]] ;;
            app:8001) [[ "$ACCESS" == "signin" && "${LLM_BAWT_MCP_AUTH_MODE:-}" == "enforce" ]] ;;
            house-h*:5173) [[ "$BAWT_HOUSE_PREVIEW_GATE" == "on" ]] ;;  # the preview gate's port only
            *)
              probe_finding 0 "port $port ($svc) is published beyond loopback but has no known authentication; unpublish it or list it in PROBE_ALLOW_PORTS"
              continue
              ;;
          esac && optout=0 || optout=1
          # An opted-out service is expected to answer; one Host is enough to say so.
          (( optout )) && hosts=("${hosts[0]}")
          for host in "${hosts[@]}"; do
            case "$svc" in
              frontend)
                probe_refusal "$optout" "frontend :$port /api/bots (Host $host)" 401 '"user_required"' \
                  "$base/api/bots" -H "Host: $host"
                probe_refusal "$optout" "frontend :$port /api/bots with forged identity headers (Host $host)" \
                  401 '"user_required"' "$base/api/bots" -H "Host: $host" \
                  -H 'Remote-User: admin' -H 'X-Forwarded-User: admin' -H 'X-BawtHub-Subject: admin'
                # With no voice backend the frontend has no upgrade route and
                # closes the socket without a reply; with one it must be 401.
                probe_refusal "$optout" "frontend :$port WebSocket upgrade (Host $host)" "$fe_upgrade_refusal" '' \
                  "$base/api/v1/ws" -H "Host: $host" "${ws_headers[@]}"
                ;;
              app)
                if [[ "$target" == "8642" ]]; then
                  probe_refusal "$optout" "app API :$port /v1/bots (Host $host)" '401|421' \
                    '"(missing_credentials|host_not_allowed)"' "$base/v1/bots" -H "Host: $host"
                  probe_refusal "$optout" "app API :$port WebSocket upgrade (Host $host)" '4[0-9][0-9]' '' \
                    "$base/v1/bots" -H "Host: $host" "${ws_headers[@]}"
                else
                  probe_refusal "$optout" "MCP :$port initialize (Host $host)" '401|421' \
                    '"(missing_credentials|service_key_required|host_not_allowed)"' "$base/mcp" -H "Host: $host" \
                    -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
                    --data "$mcp_init"
                fi
                ;;
              *)
                probe_refusal "$optout" "house preview :$port / (Host $host)" "$preview_refusal" '' "$base/" -H "Host: $host"
                probe_refusal "$optout" "house preview :$port WebSocket upgrade (Host $host)" "$preview_refusal" '' \
                  "$base/" -H "Host: $host" "${ws_headers[@]}"
                ;;
            esac
          done
        done
      done <<<"$rows"
    }
    deadline=$((SECONDS + 10#$timeout))
    app_ok=0; frontend_ok=0; voice_ok=0; agent_ok=0; houses_ok=0; tools_ok=0
    modes_ok=1; modes_final=0
    [[ "$ACCESS" != "signin" ]] || modes_ok=0
    (( HOUSES > 0 )) || houses_ok=1
    [[ "$AGENT_TOOLS" == "1" ]] || tools_ok=1
    tools_probe() { # both agent tool services pass their healthchecks
      local states
      states="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null)" || return 1
      grep -qx "playwright-mcp healthy" <<<"$states" && grep -qx "crawl4ai healthy" <<<"$states"
    }
    houses_probe() { # every house's bridge answers its healthcheck
      local states i
      states="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null)" || return 1
      for ((i = 1; i <= HOUSES; i++)); do
        grep -qx "house-h$i healthy" <<<"$states" || return 1
      done
    }
    while (( SECONDS < deadline )); do
      if (( ! app_ok )) && curl -fsS --max-time 5 "http://localhost:${app_port}/health" >/dev/null 2>&1; then
        app_ok=1; log "app /health : OK"
      fi
      if (( ! frontend_ok )) && curl -fsS --max-time 5 "http://localhost:${fe_port}/api/health" >/dev/null 2>&1; then
        frontend_ok=1; log "frontend /api/health : OK"
      fi
      if (( frontend_ok && ! voice_ok )) && voice_probe; then
        voice_ok=1; log "voice ($VOICE) : OK"
      fi
      if (( app_ok && ! agent_ok )) && agent_probe; then
        agent_ok=1; log "agent runtime : OK"
      fi
      if (( ! houses_ok )) && houses_probe; then
        houses_ok=1; log "houses ($HOUSES) : OK"
      fi
      if (( ! tools_ok )) && tools_probe; then
        tools_ok=1; log "agent tools : OK"
      fi
      if (( app_ok && ! modes_ok && ! modes_final )) && modes_probe; then
        modes_ok=1; log "auth modes (API, MCP, host guard) : OK"
      fi
      if (( app_ok && frontend_ok && voice_ok && agent_ok && houses_ok && tools_ok && modes_ok )); then
        exposure_probe
        (( exposure_failures == 0 )) || \
          die "verify failed: $exposure_failures exposure finding(s); a published port answers without credentials"
        log "exposure (published ports refuse anonymous callers) : OK"
        log "verify OK"; exit 0
      fi
      # A definite weak mode won't fix itself by waiting.
      (( modes_final )) && break
      sleep 2
    done
    (( app_ok )) || log "app /health : FAIL (port $app_port)"
    (( frontend_ok )) || log "frontend /api/health : FAIL (port $fe_port)"
    (( voice_ok )) || log "voice ($VOICE) : FAIL (pocket: model, catalog or synthesis; external: backend health)"
    (( agent_ok )) || log "agent runtime : FAIL ($agent_detail; inspect the agent-bridge logs)"
    (( houses_ok )) || log "houses : FAIL (not every house-h* bridge is healthy; inspect their logs)"
    (( tools_ok )) || log "agent tools : FAIL (playwright-mcp or crawl4ai not healthy; inspect their logs)"
    (( modes_ok )) || log "auth modes : FAIL ($modes_detail)"
    (( ! modes_final )) || die "verify failed: an auth mode is weaker than enforce"
    die "readiness timed out after $timeout seconds; inspect 'docker compose --project-name $TENANT_NAME logs'"
    ;;
  import-vault)
    [[ $# -le 1 ]] || die "import-vault takes no options"
    import_vault
    ;;
  *)
    die "unknown action: $ACTION (use: up|update [--pins FILE]|houses [--apply]|config|down|verify|paths|dev-reload|migrate-db|import-vault)"
    ;;
esac
