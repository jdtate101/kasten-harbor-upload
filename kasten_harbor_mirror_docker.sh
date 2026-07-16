#!/bin/bash
#
# kasten-harbor-mirror-docker.sh
#
# Pulls all container images for a given Kasten K10 version and pushes
# them into a private Harbor registry under the "kasten-images" project,
# preserving the upstream image/tag layout (gcr.io/kasten-images/... ->
# <harbor>/kasten-images/...).
#
# Docker edition. Unlike podman, docker has no per-command --tls-verify
# flag, so if your Harbor instance uses a self-signed cert, you must add
# it to the daemon's insecure-registries list first:
#
#   sudo tee -a /etc/docker/daemon.json <<'JSON'
#   { "insecure-registries": ["harbor.apps.openshift2.lab.home"] }
#   JSON
#   sudo systemctl restart docker
#
# (merge that key into your existing daemon.json if one already exists)
#
# Requires: docker, credentials file (see CRED_FILE below)
#
# Credentials file format (default: ./.credentials):
#   username
#   password
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Config / constants
# ---------------------------------------------------------------------------
CRED_FILE="${CRED_FILE:-.credentials}"
REGISTRY="harbor.apps.openshift2.lab.home"
HARBOR_PROJECT="kasten-images"
UPSTREAM_HOST="gcr.io"
LOG_FILE="$(mktemp -t kasten-harbor-mirror.XXXXXX.log)"

# Colours (skip if not a tty)
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

PULLED=()
FAILED_PULL=()
PUSHED=()
FAILED_PUSH=()

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
banner() {
    echo -e "${C_BOLD}${C_CYAN}=====================================================${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}   Kasten K10 -> Harbor image mirror (docker)${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}=====================================================${C_RESET}"
}

step()  { echo -e "\n${C_BOLD}${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo -e "  ${C_GREEN}✔${C_RESET} $*"; }
warn()  { echo -e "  ${C_YELLOW}!${C_RESET} $*"; }
err()   { echo -e "  ${C_RED}✘${C_RESET} $*"; }

confirm() {
    # confirm "Prompt text" -- returns 0 if user confirms, 1 otherwise
    local prompt="$1"
    local reply
    read -r -p "$(echo -e "${C_YELLOW}? ${prompt} [y/N]: ${C_RESET}")" reply < /dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Overall progress bar: draw_progress current total label
draw_progress() {
    local current=$1 total=$2 label=$3
    local width=36
    local pct=0
    (( total > 0 )) && pct=$(( current * 100 / total ))
    local filled=$(( width * pct / 100 ))
    local empty=$(( width - filled ))
    local bar
    bar=$(printf "%${filled}s" | tr ' ' '#')
    bar+=$(printf "%${empty}s" | tr ' ' '-')
    printf "\r  ${C_CYAN}[%s]${C_RESET} %3d%%  (%d/%d)  %-60s" "$bar" "$pct" "$current" "$total" "${label:0:60}"
}

# Runs a command in the background, showing a spinner + elapsed timer next
# to the overall progress bar until it completes. Returns the command's exit code.
run_with_spinner() {
    local current=$1 total=$2 label=$3; shift 3
    local spin='|/-\'
    local i=0
    local start
    start=$(date +%s)

    "$@" >>"$LOG_FILE" 2>&1 &
    local cmd_pid=$!

    while kill -0 "$cmd_pid" 2>/dev/null; do
        local now elapsed
        now=$(date +%s)
        elapsed=$(( now - start ))
        draw_progress "$current" "$total" "${label} ${spin:$((i%4)):1} ${elapsed}s"
        i=$((i+1))
        sleep 0.2
    done

    wait "$cmd_pid"
    local rc=$?
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - start ))
    if [[ $rc -eq 0 ]]; then
        draw_progress "$current" "$total" "${label} done (${elapsed}s)"
    else
        draw_progress "$current" "$total" "${label} FAILED (${elapsed}s)"
    fi
    echo
    return $rc
}

cleanup() {
    echo -e "\n\n${C_RED}Interrupted.${C_RESET} Log saved to: $LOG_FILE"
    exit 130
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
banner

command -v docker >/dev/null 2>&1 || { err "docker not found in PATH"; exit 1; }

if ! docker info 2>/dev/null | grep -A20 "Insecure Registries:" | grep -q "$REGISTRY"; then
    warn "${REGISTRY} does not appear in docker's insecure-registries list."
    warn "If Harbor uses a self-signed/internal CA cert, login/push will fail with an x509 error."
    echo "  To fix, add this to /etc/docker/daemon.json and restart docker:"
    echo "    { \"insecure-registries\": [\"${REGISTRY}\"] }"
    confirm "Continue anyway?" || { warn "Aborted by user."; exit 0; }
fi

if [[ ! -f "$CRED_FILE" ]]; then
    err "Credentials file not found: $CRED_FILE"
    echo "  Expected format:"
    echo "    username"
    echo "    password"
    exit 1
fi

HARBOR_USER=$(sed -n '1p' "$CRED_FILE")
HARBOR_PASS=$(sed -n '2p' "$CRED_FILE")

if [[ -z "$HARBOR_USER" || -z "$HARBOR_PASS" ]]; then
    err "Credentials file $CRED_FILE must contain username on line 1 and password on line 2"
    exit 1
fi

# ---------------------------------------------------------------------------
# Gather inputs
# ---------------------------------------------------------------------------
step "K10 version"
read -r -p "  Kasten K10 version to mirror (e.g. 7.0.5): " VERSION < /dev/tty
if [[ -z "$VERSION" ]]; then err "Version cannot be empty"; exit 1; fi

echo
echo -e "  Registry : ${C_BOLD}${REGISTRY}${C_RESET}"
echo -e "  Project  : ${C_BOLD}${HARBOR_PROJECT}${C_RESET}"
echo -e "  K10 ver  : ${C_BOLD}${VERSION}${C_RESET}"
echo -e "  User     : ${C_BOLD}${HARBOR_USER}${C_RESET}"
confirm "Proceed with these details?" || { warn "Aborted by user."; exit 0; }

# ---------------------------------------------------------------------------
# Login (TLS verification skipped, as requested)
# ---------------------------------------------------------------------------
step "Logging in to ${REGISTRY} (TLS verification disabled)"
if docker login "$REGISTRY" --username "$HARBOR_USER" --password "$HARBOR_PASS" >>"$LOG_FILE" 2>&1; then
    ok "Logged in to $REGISTRY"
else
    err "Login failed - see $LOG_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fetch k10tools and resolve the image list for this K10 version
# ---------------------------------------------------------------------------
step "Fetching k10tools:${VERSION} (used to enumerate images for this K10 version)"
if ! docker pull "${UPSTREAM_HOST}/kasten-images/k10tools:${VERSION}" >>"$LOG_FILE" 2>&1; then
    err "Could not pull k10tools:${VERSION} - check the version number and try again"
    exit 1
fi
ok "k10tools:${VERSION} pulled"

step "Resolving image list for K10 ${VERSION}"
IMAGE_LIST_RAW=$(docker run --rm "${UPSTREAM_HOST}/kasten-images/k10tools:${VERSION}" image list 2>>"$LOG_FILE" | tr -d '\r')
mapfile -t SOURCE_IMAGES <<< "$IMAGE_LIST_RAW"
# Drop any blank lines
SOURCE_IMAGES=("${SOURCE_IMAGES[@]/#/}")
SOURCE_IMAGES=($(printf '%s\n' "${SOURCE_IMAGES[@]}" | sed '/^\s*$/d'))

if [[ ${#SOURCE_IMAGES[@]} -eq 0 ]]; then
    err "No images returned for K10 ${VERSION} - aborting"
    exit 1
fi

ok "${#SOURCE_IMAGES[@]} images found for K10 ${VERSION}"
echo
printf '  %s\n' "${SOURCE_IMAGES[@]}" | sed "s/^/${C_DIM}/;s/$/${C_RESET}/"
echo

TOTAL=${#SOURCE_IMAGES[@]}
confirm "Pull all ${TOTAL} images from ${UPSTREAM_HOST}? (this may download several GB)" || { warn "Aborted by user."; exit 0; }

# ---------------------------------------------------------------------------
# Pull phase
# ---------------------------------------------------------------------------
step "Pulling images"
i=0
for img in "${SOURCE_IMAGES[@]}"; do
    i=$((i+1))
    short="${img#${UPSTREAM_HOST}/}"
    if run_with_spinner "$i" "$TOTAL" "pull  ${short}" docker pull "$img"; then
        PULLED+=("$img")
    else
        FAILED_PULL+=("$img")
    fi
done

echo
ok "Pulled ${#PULLED[@]}/${TOTAL} images"
if [[ ${#FAILED_PULL[@]} -gt 0 ]]; then
    warn "${#FAILED_PULL[@]} image(s) failed to pull:"
    printf '    %s\n' "${FAILED_PULL[@]}"
fi

if [[ ${#PULLED[@]} -eq 0 ]]; then
    err "Nothing was pulled successfully - nothing to push."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build retag mapping: gcr.io/kasten-images/<name>:<tag> -> <REGISTRY>/<HARBOR_PROJECT>/<name>:<tag>
# ---------------------------------------------------------------------------
step "Preparing retag mapping for ${REGISTRY}/${HARBOR_PROJECT}"
declare -A TAG_MAP
UPSTREAM_PREFIX="${UPSTREAM_HOST}/kasten-images/"
for img in "${PULLED[@]}"; do
    dest="${REGISTRY}/${HARBOR_PROJECT}/${img#${UPSTREAM_PREFIX}}"
    TAG_MAP["$img"]="$dest"
done

echo
for src in "${PULLED[@]}"; do
    echo -e "  ${C_DIM}${src}${C_RESET} -> ${C_GREEN}${TAG_MAP[$src]}${C_RESET}"
done
echo

confirm "Tag and push these ${#PULLED[@]} image(s) to ${REGISTRY}?" || { warn "Aborted by user before push - images remain in local docker storage."; exit 0; }

# ---------------------------------------------------------------------------
# Push phase
# ---------------------------------------------------------------------------
step "Tagging and pushing images"
i=0
TOTAL_PUSH=${#PULLED[@]}
for src in "${PULLED[@]}"; do
    i=$((i+1))
    dest="${TAG_MAP[$src]}"
    short="${dest#${REGISTRY}/}"

    if ! docker tag "$src" "$dest" >>"$LOG_FILE" 2>&1; then
        err "Failed to tag $src as $dest"
        FAILED_PUSH+=("$dest")
        continue
    fi

    if run_with_spinner "$i" "$TOTAL_PUSH" "push  ${short}" docker push "$dest"; then
        PUSHED+=("$dest")
    else
        FAILED_PUSH+=("$dest")
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
banner
echo -e "  K10 version   : ${C_BOLD}${VERSION}${C_RESET}"
echo -e "  Registry      : ${C_BOLD}${REGISTRY}/${HARBOR_PROJECT}${C_RESET}"
echo -e "  Pulled        : ${C_GREEN}${#PULLED[@]}${C_RESET}/${TOTAL}"
echo -e "  Pushed        : ${C_GREEN}${#PUSHED[@]}${C_RESET}/${TOTAL_PUSH}"
if [[ ${#FAILED_PULL[@]} -gt 0 || ${#FAILED_PUSH[@]} -gt 0 ]]; then
    echo -e "  ${C_RED}Failures:${C_RESET}"
    printf '    pull: %s\n' "${FAILED_PULL[@]}"
    printf '    push: %s\n' "${FAILED_PUSH[@]}"
fi
echo -e "  Log file      : ${LOG_FILE}"
echo -e "${C_BOLD}${C_CYAN}=====================================================${C_RESET}"

[[ ${#FAILED_PULL[@]} -eq 0 && ${#FAILED_PUSH[@]} -eq 0 ]]
