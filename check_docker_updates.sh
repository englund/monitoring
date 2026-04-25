#!/usr/bin/env bash
# =============================================================================
# check_docker_updates.sh
# Checks running Docker containers for available image updates.
# All updates are performed via Docker Compose.
#
# Usage:
#   ./check_docker_updates.sh                        # check only
#   ./check_docker_updates.sh --update-all           # update all outdated containers
#   ./check_docker_updates.sh --update <n> [...]     # update specific containers by name
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Argument parsing ──────────────────────────────────────────────────────────
UPDATE_ALL=false
UPDATE_SPECIFIC=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update-all)
            UPDATE_ALL=true
            shift
            ;;
        --update)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                UPDATE_SPECIFIC+=("$1")
                shift
            done
            ;;
        -h|--help)
            echo "Usage:"
            echo "  $0                          # check only"
            echo "  $0 --update-all             # update all outdated containers via Compose"
            echo "  $0 --update name1 name2     # update specific services by Compose service name"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${RESET}"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
should_update() {
    local name="$1"
    $UPDATE_ALL && return 0
    for target in "${UPDATE_SPECIFIC[@]}"; do
        [[ "$target" == "$name" ]] && return 0
    done
    return 1
}

# Update a container using its Compose project metadata
compose_update() {
    local container_name="$1"
    local service="$2"
    local compose_file="$3"

    echo -e "  ${CYAN}↓ Pulling new image...${RESET}"
    if ! docker compose -f "$compose_file" pull "$service"; then
        echo -e "  ${RED}✘ Pull failed${RESET}"
        return 1
    fi

    echo -e "  ${CYAN}♻ Recreating service: ${service}${RESET}"
    if docker compose -f "$compose_file" up -d --no-deps "$service"; then
        echo -e "  ${GREEN}✔ Updated successfully${RESET}"
        return 0
    else
        echo -e "  ${RED}✘ Failed to recreate container${RESET}"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
updates_found=0
updates_done=0
checked=0

# Track which Compose projects we've already updated (avoid duplicate pulls)
declare -A updated_projects

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║       Docker Container Update Checker        ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
echo ""

if $UPDATE_ALL; then
    echo -e "  ${YELLOW}Mode: Update all outdated containers (via Compose)${RESET}"
elif [[ ${#UPDATE_SPECIFIC[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Mode: Update specific services — ${UPDATE_SPECIFIC[*]} (via Compose)${RESET}"
else
    echo -e "  Mode: Check only"
    echo -e "  ${CYAN}Tip: Use --update-all or --update <name> [name2 ...] to update${RESET}"
fi
echo ""

mapfile -t containers < <(docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}')

if [[ ${#containers[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No running containers found.${RESET}"
    exit 0
fi

for entry in "${containers[@]}"; do
    IFS='|' read -r container_id container_name image <<< "$entry"

    # If specific services were requested, skip everything else.
    # We need the compose service name first, so peek at the label here.
    container_service=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.service"}}' "$container_name" 2>/dev/null || true)
    if [[ ${#UPDATE_SPECIFIC[@]} -gt 0 ]] && ! should_update "${container_service:-$container_name}"; then
        continue
    fi

    echo -e "${BOLD}Container:${RESET} ${container_name} (${container_id:0:12})"
    echo -e "  Image   : ${image}"

    # ── Compose metadata ──────────────────────────────────────────────────────
    compose_file=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_name" 2>/dev/null || true)
    compose_service="${container_service}"  # already fetched above

    if [[ -z "$compose_file" || -z "$compose_service" ]]; then
        echo -e "  ${YELLOW}⚠ Not a Compose container — skipping${RESET}"
        echo ""
        continue
    fi

    echo -e "  Service : ${compose_service} (${compose_file})"

    # ── Digest check (no pull — registry API only) ────────────────────────────
    # Get the local digest from the running image
    local_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null \
        | sed 's/.*@//' || true)

    # If RepoDigests is empty, try the image ID as fallback identifier
    if [[ -z "$local_digest" ]]; then
        local_digest=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || true)
    fi

    if [[ -z "$local_digest" ]]; then
        echo -e "  ${YELLOW}⚠ Could not inspect local image${RESET}"
        echo ""
        continue
    fi

    # Parse image into registry/repository:tag parts
    # Examples:
    #   jellyfin/jellyfin            → registry=registry-1.docker.io repo=jellyfin/jellyfin tag=latest
    #   ghcr.io/home-assistant/..    → registry=ghcr.io repo=home-assistant/... tag=stable
    registry=""
    repository=""
    tag="latest"

    # Split off tag
    if [[ "$image" == *:* ]]; then
        tag="${image##*:}"
        image_notag="${image%:*}"
    else
        image_notag="$image"
    fi

    # Split off registry (contains a dot or colon, or is "localhost")
    first_component="${image_notag%%/*}"
    if [[ "$first_component" == *"."* || "$first_component" == *":"* || "$first_component" == "localhost" ]]; then
        registry="$first_component"
        repository="${image_notag#*/}"
    else
        registry="registry-1.docker.io"
        # Docker Hub images with no slash get library/ prefix
        if [[ "$image_notag" != *"/"* ]]; then
            repository="library/${image_notag}"
        else
            repository="$image_notag"
        fi
    fi

    echo -e "  ${CYAN}Checking registry...${RESET}"

    # Fetch remote digest via registry API (no pull)
    remote_digest=""

    # Fetch remote digest via registry API (no pull).
    # Many registries require a Bearer token even for public images.
    # Strategy: try unauthenticated first; if we get a 401, parse the
    # WWW-Authenticate header to find the token endpoint and fetch a token.
    manifest_url="https://${registry}/v2/${repository}/manifests/${tag}"
    accept_headers=(
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
        -H "Accept: application/vnd.oci.image.manifest.v1+json"
        -H "Accept: application/vnd.oci.image.index.v1+json"
    )

    # First attempt — unauthenticated
    response=$(curl -sf --head "${accept_headers[@]}" "$manifest_url" 2>/dev/null || true)
    remote_digest=$(echo "$response" | grep -i "^docker-content-digest:" | tr -d '\r' | awk '{print $2}' || true)

    # If no digest, try to get a token via WWW-Authenticate
    if [[ -z "$remote_digest" ]]; then
        www_auth=$(curl -si --head "${accept_headers[@]}" "$manifest_url" 2>/dev/null \
            | grep -i "^www-authenticate:" | tr -d '\r' || true)

        if [[ -n "$www_auth" ]]; then
            token_url=$(echo "$www_auth" | grep -oP 'realm="\K[^"]+' || true)
            token_service=$(echo "$www_auth" | grep -oP 'service="\K[^"]+' || true)
            token_scope=$(echo "$www_auth" | grep -oP 'scope="\K[^"]+' || true)

            if [[ -n "$token_url" ]]; then
                token=$(curl -sf "${token_url}?service=${token_service}&scope=${token_scope}" \
                    | grep -oP '"token"\s*:\s*"\K[^"]+' || true)

                if [[ -n "$token" ]]; then
                    remote_digest=$(curl -sf --head \
                        -H "Authorization: Bearer ${token}" \
                        "${accept_headers[@]}" \
                        "$manifest_url" \
                        | grep -i "^docker-content-digest:" | tr -d '\r' | awk '{print $2}' || true)
                fi
            fi
        fi
    fi

    if [[ -z "$remote_digest" ]]; then
        echo -e "  ${YELLOW}⚠ Could not fetch remote digest (registry unreachable or auth required)${RESET}"
        echo ""
        continue
    fi

    if [[ "$local_digest" == "$remote_digest" ]]; then
        echo -e "  Status  : ${GREEN}✔ Up to date${RESET}"
    else
        echo -e "  Status  : ${RED}✘ UPDATE AVAILABLE${RESET}"
        echo -e "  ${YELLOW}Local :${RESET}  ${local_digest:7:20}..."
        echo -e "  ${YELLOW}Remote:${RESET}  ${remote_digest:7:20}..."
        (( updates_found++ )) || true

        if should_update "$compose_service"; then
            echo ""
            if compose_update "$container_name" "$compose_service" "$compose_file"; then
                (( updates_done++ )) || true
            fi
        fi
    fi

    (( checked++ )) || true
    echo ""
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}──────────────────────────────────────────────${RESET}"
echo -e "  Containers checked : ${checked}"
pending=$(( updates_found - updates_done ))
if [[ $updates_done -gt 0 ]]; then
    echo -e "  Updates applied    : ${GREEN}${BOLD}${updates_done}${RESET}"
fi
if [[ $pending -gt 0 ]]; then
    echo -e "  Updates pending    : ${RED}${BOLD}${pending}${RESET}"
fi
if [[ $updates_found -eq 0 ]]; then
    echo -e "  Updates available  : ${GREEN}${BOLD}0 — all good!${RESET}"
fi
echo -e "${BOLD}${CYAN}──────────────────────────────────────────────${RESET}"
echo ""

[[ $updates_found -eq 0 ]]