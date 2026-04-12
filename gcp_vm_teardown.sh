#!/usr/bin/env bash
# =============================================================================
# gcp_vm_teardown.sh
#
# Interactively tears down a GCP VM and all associated resources:
#   - VM instance(s)
#   - Persistent disk snapshots / backup policies (snapshot schedules)
#   - Cloud Scheduler jobs (only removed when ALL VMs in project are torn down)
#   - Resource policies (instance schedule policies)
#   - Reserved (static) external IP address
#
# Prerequisites:
#   - gcloud CLI installed and authenticated  (gcloud auth login)
#   - jq  (sudo apt install jq  /  brew install jq)
# =============================================================================

set -euo pipefail

# ---------- helpers -----------------------------------------------------------

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

confirm() {
  local msg="$1"
  while true; do
    read -rp "$(echo -e "${YELLOW}${msg} [y/N]: ${RESET}")" ans
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

pick_from_list() {
  local prompt="$1"; shift
  local items=("$@")
  if [[ ${#items[@]} -eq 0 ]]; then return 1; fi
  echo ""
  local i=1
  for item in "${items[@]}"; do
    echo -e "  ${BOLD}${i})${RESET} ${item}"
    ((i++))
  done
  echo ""
  while true; do
    read -rp "$(echo -e "${YELLOW}${prompt} (1-${#items[@]}): ${RESET}")" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
      PICKED="${items[$((choice-1))]}"
      return 0
    fi
    echo "Invalid choice. Please enter a number between 1 and ${#items[@]}."
  done
}

require_cmd() {
  command -v "$1" &>/dev/null || {
    error "'$1' is required but not installed.  $2"
    exit 1
  }
}

# ---------- per-instance resource discovery -----------------------------------

discover_instance_resources() {
  local iname="$1" izone="$2"

  info "Fetching details for instance: ${BOLD}${iname}${RESET} …"
  local inst_json
  inst_json=$(gcloud compute instances describe "$iname" \
    --zone="$izone" --project="$PROJECT_ID" --format=json 2>/dev/null)

  mapfile -t DISK_NAMES < <(echo "$inst_json" | jq -r '.disks[].source' | sed 's|.*/||')

  STATIC_IPS=()
  while IFS=$'\t' read -r name region addr _status; do
    local users
    users=$(gcloud compute addresses describe "$name" \
      --region="$region" --project="$PROJECT_ID" \
      --format="value(users)" 2>/dev/null || true)
    if echo "$users" | grep -q "$iname"; then
      STATIC_IPS+=("$name|$region|$addr")
    fi
  done < <(gcloud compute addresses list \
    --project="$PROJECT_ID" \
    --format="value(name,region,address,status)" 2>/dev/null)

  mapfile -t RESOURCE_POLICIES < <(
    echo "$inst_json" | jq -r '.resourcePolicies[]? // empty' | sed 's|.*/||'
  )

  SNAP_SCHEDULES=()
  local disk_region
  disk_region=$(echo "$izone" | sed 's/-[a-z]$//')
  for disk in "${DISK_NAMES[@]}"; do
    local disk_json
    disk_json=$(gcloud compute disks describe "$disk" \
      --zone="$izone" --project="$PROJECT_ID" \
      --format=json 2>/dev/null || echo "{}")
    mapfile -t DPOLICIES < <(echo "$disk_json" | jq -r '.resourcePolicies[]? // empty' | sed 's|.*/||')
    for dp in "${DPOLICIES[@]}"; do
      if [[ ! " ${RESOURCE_POLICIES[*]} " =~ " ${dp} " ]]; then
        SNAP_SCHEDULES+=("$dp|$disk_region")
      fi
    done
  done

  SNAPSHOTS=()
  for disk in "${DISK_NAMES[@]}"; do
    mapfile -t DSNAPS < <(
      gcloud compute snapshots list \
        --project="$PROJECT_ID" \
        --filter="sourceDisk~'$disk'" \
        --format="value(name)" 2>/dev/null
    )
    SNAPSHOTS+=("${DSNAPS[@]}")
  done
}

print_instance_resources() {
  local iname="$1" izone="$2"
  echo -e "  ${BOLD}Instance    :${RESET} $iname  (zone: $izone)"
  echo -e "  ${BOLD}Disks       :${RESET} ${DISK_NAMES[*]:-none}"
  echo -e "  ${BOLD}Snapshots   :${RESET} ${SNAPSHOTS[*]:-none}"
  echo -e "  ${BOLD}Snap scheds :${RESET} ${SNAP_SCHEDULES[*]:-none}"
  echo -e "  ${BOLD}Res policies:${RESET} ${RESOURCE_POLICIES[*]:-none}"
  echo -e "  ${BOLD}Static IPs  :${RESET} ${STATIC_IPS[*]:-none}"
}

# ---------- teardown one instance ---------------------------------------------

teardown_instance() {
  local iname="$1" izone="$2"
  local rp_region
  rp_region=$(echo "$izone" | sed 's/-[a-z]$//')

  for rp in "${RESOURCE_POLICIES[@]:-}"; do
    [[ -z "$rp" ]] && continue
    info "Detaching resource policy '$rp' from $iname …"
    gcloud compute instances remove-resource-policies "$iname" \
      --resource-policies="$rp" \
      --zone="$izone" --project="$PROJECT_ID" \
      --quiet 2>/dev/null || warn "Could not detach policy $rp."
    info "Deleting resource policy: $rp …"
    if gcloud compute resource-policies delete "$rp" \
        --region="$rp_region" --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then
      success "Deleted resource policy: $rp"
    else
      warn "Could not delete resource policy $rp."
    fi
  done

  for entry in "${SNAP_SCHEDULES[@]:-}"; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r schedname schedreg <<< "$entry"
    for disk in "${DISK_NAMES[@]:-}"; do
      [[ -z "$disk" ]] && continue
      gcloud compute disks remove-resource-policies "$disk" \
        --resource-policies="$schedname" \
        --zone="$izone" --project="$PROJECT_ID" \
        --quiet 2>/dev/null || true
    done
    info "Deleting snapshot schedule: $schedname …"
    if gcloud compute resource-policies delete "$schedname" \
        --region="$schedreg" --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then
      success "Deleted snapshot schedule: $schedname"
    else
      warn "Could not delete snapshot schedule $schedname."
    fi
  done

  info "Deleting VM instance: $iname …"
  gcloud compute instances delete "$iname" \
    --zone="$izone" --project="$PROJECT_ID" \
    --keep-disks=all --quiet
  success "VM instance deleted: $iname"

  for snap in "${SNAPSHOTS[@]:-}"; do
    [[ -z "$snap" ]] && continue
    info "Deleting snapshot: $snap …"
    if gcloud compute snapshots delete "$snap" \
        --project="$PROJECT_ID" --quiet 2>/dev/null; then
      success "Deleted snapshot: $snap"
    else
      warn "Could not delete snapshot $snap."
    fi
  done

  for disk in "${DISK_NAMES[@]:-}"; do
    [[ -z "$disk" ]] && continue
    info "Deleting disk: $disk …"
    if gcloud compute disks delete "$disk" \
        --zone="$izone" --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then
      success "Deleted disk: $disk"
    else
      warn "Could not delete disk $disk (may already be gone)."
    fi
  done

  for entry in "${STATIC_IPS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r ipname ipreg ipaddr <<< "$entry"
    info "Releasing static IP: $ipname ($ipaddr) …"
    if gcloud compute addresses delete "$ipname" \
        --region="$ipreg" --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then
      success "Released static IP: $ipname"
    else
      warn "Could not release IP $ipname."
    fi
  done
}

# ---------- Cloud Scheduler discovery (by client_hash) ------------------------

find_scheduler_jobs() {
  local hash="$1"
  SCHEDULER_JOBS=()

  info "Searching Cloud Scheduler jobs for client hash ${BOLD}${hash}${RESET} …"
  mapfile -t LOCATIONS < <(
    gcloud scheduler locations list \
      --project="$PROJECT_ID" \
      --format="value(locationId)" 2>/dev/null || true
  )

  for loc in "${LOCATIONS[@]}"; do
    mapfile -t LOC_JOBS < <(
      gcloud scheduler jobs list \
        --project="$PROJECT_ID" \
        --location="$loc" \
        --format="value(name)" 2>/dev/null || true
    )
    for job in "${LOC_JOBS[@]:-}"; do
      [[ -z "$job" ]] && continue
      local job_json body
      job_json=$(gcloud scheduler jobs describe "$job" \
        --project="$PROJECT_ID" --location="$loc" \
        --format=json 2>/dev/null || echo "{}")
      body=$(echo "$job_json" | jq -r '.httpTarget.body // ""' | base64 -d 2>/dev/null || true)
      if echo "$body" | grep -q "$hash"; then
        local job_short
        job_short=$(echo "$job" | sed 's|.*/||')
        SCHEDULER_JOBS+=("${job_short}|${loc}")
        echo "    • ${job_short}  (location: ${loc})"
      fi
    done
  done

  if [[ ${#SCHEDULER_JOBS[@]} -eq 0 ]]; then
    info "  No Cloud Scheduler jobs found for hash $hash."
  fi
}

delete_scheduler_jobs() {
  for entry in "${SCHEDULER_JOBS[@]}"; do
    IFS='|' read -r jobname jobloc <<< "$entry"
    info "Deleting Cloud Scheduler job: $jobname …"
    if gcloud scheduler jobs delete "$jobname" \
        --location="$jobloc" --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then
      success "Deleted scheduler job: $jobname"
    else
      warn "Could not delete scheduler job $jobname (may already be gone)."
    fi
  done
}

# ---------- extract client hash from resource names ---------------------------

extract_hash() {
  # Resource policy names: sched-{hash}-vmname
  # Static IP names:       vmname-{hash}-ip
  # Both contain a 10-char hex segment bounded by hyphens
  local hash=""
  for rp in "${RESOURCE_POLICIES[@]:-}" "${STATIC_IPS[@]:-}"; do
    [[ -z "$rp" ]] && continue
    hash=$(echo "$rp" | grep -oP '(?<=-)[0-9a-f]{10}(?=[-|])' | head -1 || true)
    if [[ -n "$hash" ]]; then break; fi
  done
  echo "$hash"
}

# =============================================================================
# MAIN
# =============================================================================

require_cmd gcloud "See https://cloud.google.com/sdk/docs/install"
require_cmd jq     "Install with: sudo apt install jq  OR  brew install jq"

header "GCP VM Teardown Script"
echo "This script removes a VM and all its related resources."
echo "You will be asked to confirm before any deletions occur."

# ---------- Step 1: Select project --------------------------------------------

header "Step 1 – Select Project"

mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" 2>/dev/null | sort)
if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  error "No accessible GCP projects found. Check your authentication (gcloud auth login)."
  exit 1
fi

pick_from_list "Select project" "${PROJECTS[@]}"
PROJECT_ID="$PICKED"
gcloud config set project "$PROJECT_ID" --quiet
success "Active project: ${BOLD}${PROJECT_ID}${RESET}"

# ---------- Step 2: List VMs and choose scope ---------------------------------

header "Step 2 – Select Scope"

info "Fetching all VM instances in project ${PROJECT_ID} …"
mapfile -t INSTANCES < <(
  gcloud compute instances list \
    --format="value(name,zone)" \
    --project="$PROJECT_ID" 2>/dev/null \
  | awk '{print $1 "  (zone: " $2 ")"}' | sort
)

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
  error "No VM instances found in project ${PROJECT_ID}."
  exit 1
fi

TEARDOWN_ALL=false

if [[ ${#INSTANCES[@]} -gt 1 ]]; then
  echo ""
  echo -e "  ${BOLD}${#INSTANCES[@]} instances found in this project:${RESET}"
  for inst in "${INSTANCES[@]}"; do echo "    • $inst"; done
  echo ""
  echo -e "  ${BOLD}1)${RESET} Tear down a single VM  (scheduler job preserved)"
  echo -e "  ${BOLD}2)${RESET} Tear down ALL VMs       (scheduler job also removed)"
  echo ""
  while true; do
    read -rp "$(echo -e "${YELLOW}Choose scope (1 or 2): ${RESET}")" scope_choice
    case "$scope_choice" in
      1) TEARDOWN_ALL=false; break ;;
      2) TEARDOWN_ALL=true;  break ;;
      *) echo "Please enter 1 or 2." ;;
    esac
  done
fi

# ---------- Step 3: Select instance(s) ----------------------------------------

header "Step 3 – Confirm Instances"

TARGET_NAMES=()
TARGET_ZONES=()

if [[ "$TEARDOWN_ALL" == true ]]; then
  info "All instances selected for teardown."
  for inst in "${INSTANCES[@]}"; do
    TARGET_NAMES+=( "$(echo "$inst" | awk '{print $1}')" )
    TARGET_ZONES+=( "$(echo "$inst" | grep -oP 'zone: \K[^\)]+' | sed 's|.*/||')" )
  done
else
  pick_from_list "Select instance to tear down" "${INSTANCES[@]}"
  TARGET_NAMES+=( "$(echo "$PICKED" | awk '{print $1}')" )
  TARGET_ZONES+=( "$(echo "$PICKED" | grep -oP 'zone: \K[^\)]+' | sed 's|.*/||')" )
fi

# ---------- Step 4: Discover resources ----------------------------------------

header "Step 4 – Discovering Resources"

CLIENT_HASH=""
declare -A INST_DISKS INST_IPS INST_POLICIES INST_SNAP_SCHEDS INST_SNAPS

for idx in "${!TARGET_NAMES[@]}"; do
  iname="${TARGET_NAMES[$idx]}"
  izone="${TARGET_ZONES[$idx]}"

  discover_instance_resources "$iname" "$izone"

  INST_DISKS[$iname]=$(printf '%s\n' "${DISK_NAMES[@]:-}")
  INST_IPS[$iname]=$(printf '%s\n' "${STATIC_IPS[@]:-}")
  INST_POLICIES[$iname]=$(printf '%s\n' "${RESOURCE_POLICIES[@]:-}")
  INST_SNAP_SCHEDS[$iname]=$(printf '%s\n' "${SNAP_SCHEDULES[@]:-}")
  INST_SNAPS[$iname]=$(printf '%s\n' "${SNAPSHOTS[@]:-}")

  print_instance_resources "$iname" "$izone"
  echo ""

  if [[ -z "$CLIENT_HASH" ]]; then
    CLIENT_HASH=$(extract_hash "$iname")
  fi
done

# Scheduler jobs — only look up when tearing down all VMs
SCHEDULER_JOBS=()
if [[ "$TEARDOWN_ALL" == true ]]; then
  if [[ -n "$CLIENT_HASH" ]]; then
    find_scheduler_jobs "$CLIENT_HASH"
  else
    warn "Could not determine client hash from resource names."
    warn "Scheduler jobs will NOT be removed automatically."
    warn "List them manually: gcloud scheduler jobs list --project=$PROJECT_ID --location=us-central1"
  fi
else
  info "Single-VM teardown — scheduler job will be preserved."
fi

# ---------- Step 5: Confirm ---------------------------------------------------

header "Step 5 – Confirm Teardown Plan"
echo ""
echo -e "  ${BOLD}Project     :${RESET} $PROJECT_ID"
if [[ "$TEARDOWN_ALL" == true ]]; then
  echo -e "  ${BOLD}Scope       :${RESET} ALL instances (${#TARGET_NAMES[@]} VMs)"
else
  echo -e "  ${BOLD}Scope       :${RESET} Single instance: ${TARGET_NAMES[0]}"
fi
if [[ ${#SCHEDULER_JOBS[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Scheduler   :${RESET} ${SCHEDULER_JOBS[*]}"
else
  echo -e "  ${BOLD}Scheduler   :${RESET} none (preserved)"
fi
echo ""
warn "ALL listed resources will be PERMANENTLY DELETED."

if ! confirm "Proceed with teardown?"; then
  info "Aborted. Nothing was deleted."
  exit 0
fi

# ---------- Step 6: Execute teardown ------------------------------------------

header "Step 6 – Tearing Down"

# Delete scheduler jobs first (before VMs are gone)
if [[ ${#SCHEDULER_JOBS[@]} -gt 0 ]]; then
  delete_scheduler_jobs
fi

for idx in "${!TARGET_NAMES[@]}"; do
  iname="${TARGET_NAMES[$idx]}"
  izone="${TARGET_ZONES[$idx]}"

  echo ""
  info "--- Tearing down: ${BOLD}${iname}${RESET} ---"

  mapfile -t DISK_NAMES        < <(echo "${INST_DISKS[$iname]}"       | grep -v '^$' || true)
  mapfile -t STATIC_IPS        < <(echo "${INST_IPS[$iname]}"         | grep -v '^$' || true)
  mapfile -t RESOURCE_POLICIES < <(echo "${INST_POLICIES[$iname]}"    | grep -v '^$' || true)
  mapfile -t SNAP_SCHEDULES    < <(echo "${INST_SNAP_SCHEDS[$iname]}" | grep -v '^$' || true)
  mapfile -t SNAPSHOTS         < <(echo "${INST_SNAPS[$iname]}"       | grep -v '^$' || true)

  teardown_instance "$iname" "$izone"
done

# ---------- done --------------------------------------------------------------

header "Teardown Complete"
if [[ "$TEARDOWN_ALL" == true ]]; then
  success "All instances and associated resources removed from project '${PROJECT_ID}'."
else
  success "Instance '${TARGET_NAMES[0]}' and its resources removed from project '${PROJECT_ID}'."
fi
echo ""
