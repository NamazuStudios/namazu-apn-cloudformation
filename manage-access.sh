#!/usr/bin/env bash
# manage-access.sh — interactive manager for the Namazu co-selling
# agent's customer-side access. THE MODEL: one CloudFormation stack, one
# IAM role. Create (option 1) is ONE SHOT: it needs nothing but the
# external ID (generated unless --external-id) and deploys the role with
# its trust authorizing NOBODY (an explicit deny for every principal).
# Access is then exactly two decisions, wired after create: the
# authorized user (set authorized-user=… — the attribution) and the
# principals (options 2/4 — the agents' per-workspace runner roles,
# constructed from <user_name>=<workspace-id> pairs). The trust's Allow
# branch exists only when BOTH are set. Delete the stack and the role
# goes with it. Gate flips (options 5-8) and the on-demand ticket
# report (option 9) round it out.
#
# Requirements: bash + the AWS CLI, authenticated as a principal allowed
# to create IAM roles in the AWS account linked to your Partner Central
# account. No other dependencies (no jq — parsing is done with --query).
#
# Usage: ./manage-access.sh [--stack-name NAME] [--region REGION]
#                        [--external-id VALUE]
#
# Copyright 2026 Namazu Studios LLC. Licensed AGPL-3.0 — see LICENSE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ONE template, ONE model: a stack, a role, a principal list. Create
# (option 1) is one shot — it needs nothing but the ExternalId (generated
# unless --external-id) and deploys the role with its trust authorizing
# NOBODY. Access is then exactly two decisions, wired after create: the
# authorized user (set authorized-user=…) and the principals (options 2/4).
TEMPLATE="$SCRIPT_DIR/templates/opportunity-manager-role.yaml"
STACK_NAME="namazu-cosell-manager"

EXTID_RE='^[A-Za-z0-9_+=,.@-]{2,1224}$'

# Namazu's hosting account — where the per-workspace runner roles live.
# A product constant; the customer's stack pins its trust to runners in
# this account, named cosell-agent-<user_name>-<workspace-id>.
NAMAZU_ACCOUNT=308044622771

# The workspace half of a runner pair: the 24-hex instance/workspace id
# Namazu Cloud shows for the tenant's deployment.
WS_RE='^[0-9a-f]{24}$'

# The user_name half: the operator-chosen tracking label. IAM charset,
# capped at 20 characters — the addon's terraform truncates to 20
# (substr(...,0,20)) when it names the runner, so staying within 20
# guarantees the ARN this script constructs equals the role the addon
# creates.
UNAME_RE='^[A-Za-z0-9_+=,.@-]{2,20}$'

die() { echo "error: $*" >&2; exit 1; }
say() { echo; echo "$*"; }

# Pretty heading — bordered and centered from its own copy, so it can't
# misalign however the wording changes.
banner() {
  local l w=0 pad
  local lines=(
    ''
    'N A M A Z U   S T U D I O S'
    'co-selling agent access manager'
    ''
  )
  for l in ${lines[@]+"${lines[@]}"}; do (( ${#l} > w )) && w=${#l}; done
  local border="" i
  for ((i = 0; i < w + 4; i++)); do border+="─"; done
  echo "┌${border}┐"
  for l in ${lines[@]+"${lines[@]}"}; do
    pad=$(( (w + 4 - ${#l}) / 2 ))
    printf '│%*s%s%*s│\n' "$pad" '' "$l" "$(( w + 4 - ${#l} - pad ))" ''
  done
  echo "└${border}┘"
}

usage() {
  cat <<'EOF'
manage-access.sh — manage Namazu co-selling agent access (interactive)

Usage: ./manage-access.sh [--stack-name NAME] [--region REGION]

  --stack-name   the CloudFormation stack to manage
                 (default: namazu-cosell-manager — the shared-role stack)
  --region       AWS region for the CloudFormation calls
                 (default: your AWS CLI's configured region)
  --external-id  supply the external ID instead of generating one
                 (the one-shot create generates a random 32-char secret
                 unless this is given)

Menu: create the access stack (the role exists; its trust authorizes
nobody), add/remove the principals that may assume it (the agents'
runner roles, constructed from <user_name>=<workspace-id> pairs), flip
the capability gates, print the ticket report to send Namazu, or
delete the stack (the role goes with it). `ticket` reprints the full
report on demand; in the menu, 'h' shows a detailed help.

Requires: bash, the AWS CLI, and credentials for the AWS account linked
to your Partner Central account. Deploys
templates/opportunity-manager-role.yaml — the only template: one role,
one principal list.
EOF
}

# ---- flags ------------------------------------------------------------------
YES=0; JSON=0; EXTERNAL_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name) [[ $# -ge 2 ]] || die "--stack-name needs a value"; STACK_NAME="$2"; shift 2 ;;
    --region)     [[ $# -ge 2 ]] || die "--region needs a value"; AWS_DEFAULT_REGION="$2"; export AWS_DEFAULT_REGION; shift 2 ;;
    --external-id) [[ $# -ge 2 ]] || die "--external-id needs a value"; EXTERNAL_ID="$2"; shift 2 ;;
    --yes)        YES=1; shift ;;
    --json)       JSON=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            break ;;   # first non-flag argument: the subcommand
  esac
done
COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift

# ---- helpers ----------------------------------------------------------------
stack_status() { # one lightweight round trip: just the stack status
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null
}
stack_exists() { [[ -n "$(stack_status)" ]] ; }

# All the describe-stacks data the script ever reads — status, the Users
# parameter, every stack parameter, and the RoleArn outputs — fetched as
# four CONCURRENT calls. Each `aws` invocation pays CLI startup + auth +
# a network round trip, so four sequential queries made listing crawl;
# parallel they cost about one round trip. Snapshots are taken fresh at
# the start of an action and re-taken after any mutation, so readers
# never see stale data.
SNAP_DIR=""
snapshot_stack() {
  cleanup_snapshot
  SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp/opencode}/namazu-snap.XXXXXX" 2>/dev/null)" \
    || SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/namazu-snap.XXXXXX")" \
    || die "cannot create a temp dir"
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null >"$SNAP_DIR/status" &
  # (The JMESPath literal backticks below are intentional — no shell expansion.)
  # shellcheck disable=SC2016
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[?starts_with(OutputKey, `RoleArn`)].[OutputKey,OutputValue]' \
    --output text 2>/dev/null >"$SNAP_DIR/arns" &
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' \
    --output text 2>/dev/null >"$SNAP_DIR/params" &
  wait
}
cleanup_snapshot() {
  [[ -n "$SNAP_DIR" ]] && rm -rf "$SNAP_DIR"
  SNAP_DIR=""
}
trap cleanup_snapshot EXIT
trap 'cleanup_snapshot; exit 130' INT TERM

snap_status() { cat "$SNAP_DIR/status" 2>/dev/null; }

# True when the stack's template carries the parameter at all (its value
# may still be empty — an empty AgentRoleArns is a real state, not an
# unmanaged one).
param_defined() { # $1 = key
  awk -F'\t' -v k="$1" '$1 == k { found=1 } END { exit !found }' "$SNAP_DIR/params" 2>/dev/null
}

# One stack parameter from the current snapshot (empty when absent).
snap_param() { # $1 = parameter key
  awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$SNAP_DIR/params" 2>/dev/null
}

# `aws cloudformation deploy` resets any parameter it is NOT given back to
# the template's default — so before any update we read the stack's current
# parameters and re-pass every one of them, substituting only the values the
# caller asks for. Without this, adding a second user (or changing the
# catalog) would silently wipe a CatalogPin or ExternalId set at creation
# time.
deploy_with_overrides() { # $@ = KEY=VALUE pairs to substitute into the snapshot
  [[ -n "$SNAP_DIR" ]] || snapshot_stack
  local -A ov=()
  local pair k v
  for pair in "$@"; do
    k="${pair%%=*}"
    ov["$k"]="${pair#*=}"
  done
  local overrides=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    [[ -n "${ov["$k"]+x}" ]] && v="${ov["$k"]}"
    overrides+=("$k=$v")
  done < "$SNAP_DIR/params"
  aws cloudformation deploy \
    --template-file "$TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ${overrides[@]+"${overrides[@]}"}
}

events_hint() {
  echo "  for the reason: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region <your-region>"
}

# ---- ticket report -----------------------------------------------------------
# Everything the operator needs to put into a support ticket for Namazu:
# the ExternalId secret, the trusted runner principals, every role ARN,
# and the contract entries rendered in the exact shape the Namazu
# deployment contract (the agent_apn block) carries. Read-only — built
# entirely from the snapshot, so it always reflects the live stack.
# Printed after create and add-user, and on demand (menu option 9 /
# `ticket`), so the ticket a customer sends is never assembled by hand.

# The stack's single RoleArn output.
ticket_role_arn() {
  awk -F'\t' -v k="RoleArn" '$1 == k { print $2; exit }' "$SNAP_DIR/arns" 2>/dev/null
}

# One contract-entry block — the five agent_apn fields this stack
# governs, in the same shape they take in the deployment contract.
ticket_entry() { # $1=note $2=consume_role_arn $3=user_name $4=source_identity
  local extid catalog
  extid="$(snap_param ExternalId)"
  catalog="$(snap_param CatalogPin)"
  echo "  # $1"
  echo "  \"consume_role_arn\": \"${2:-<pending — see ROLES above>}\","
  echo "  \"user_name\":        \"${3:-<confirm with Namazu>}\","
  echo "  \"source_identity\":  \"${4:-<confirm with Namazu>}\","
  echo "  \"external_id\":      \"${extid:-<not set — required: redeploy>}\","
  echo "  \"catalog\":          \"${catalog:-Sandbox}\""
}

# The user_name half of a runner principal's role name. Runner roles
# are named cosell-agent-<user_name>-<workspace>, the workspace being a
# 24-hex id at the tail — greedy user_name capture anchored on that.
runner_user_name() { # $1 = runner role ARN; echoes "user workspace" or nothing
  local name="${1##*/}"
  [[ "$name" =~ ^cosell-agent-(.+)-([0-9a-f]{24})$ ]] \
    && echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
}

print_ticket_report() {
  snapshot_stack
  local status extid agents auser
  status="$(snap_status)"
  if [[ -z "$status" ]]; then
    echo "no stack $STACK_NAME — nothing to report (option 1 creates it)"
    return 1
  fi
  extid="$(snap_param ExternalId)"
  agents="$(snap_param AgentRoleArns)"
  auser="$(snap_param AuthorizedUser)"
  local bar a uw rarn g
  bar="$(printf '%0.s─' $(seq 1 64))"

  say "$bar"
  echo "TICKET REPORT — Namazu co-selling agent access"
  echo "send this to Namazu (a support ticket works): it is everything"
  echo "they need to wire the agent deployment to the roles below."
  echo "$bar"
  echo "account:  $account"
  echo "region:   $region"
  echo "stack:    $STACK_NAME ($status)"

  echo
  echo "NAMAZU CLOUD WORKSPACE(S) — the deployment(s) this ticket wires;"
  echo "each id is the instance/workspace the agent runs in:"
  if [[ -n "$agents" ]]; then
    while IFS= read -r a; do
      [[ -n "$a" ]] || continue
      uw="$(runner_user_name "$a")"
      if [[ -n "$uw" ]]; then
        echo "  ${uw##* }   user_name: ${uw%% *}"
      else
        echo "  <principal ${a##*/} carries no workspace — confirm with Namazu>"
      fi
    done < <(tr ',' '\n' <<< "$agents")
    echo "  (decoded from the runner principal names — these are the"
    echo "   workspace pairs behind the principals (option 2); verify"
    echo "   they are your workspaces before sending)"
  else
    echo "  (none yet — the workspaces come with the principals: add them"
    echo "   with menu option 2 and the pairs carry the workspace ids)"
  fi

  echo
  echo "EXTERNAL ID (secret — every assume-role must present it; any"
  echo "mismatch is a total deny):"
  echo "  ${extid:-<not set — required: redeploy with the current template>}"

  echo
  if [[ -n "$agents" ]]; then
    echo "TRUSTED PRINCIPALS (from AgentRoleArns — only these runner roles"
    echo "may assume, and each still needs SourceIdentity + the external ID):"
    while IFS= read -r a; do
      [[ -n "$a" ]] || continue
      uw="$(runner_user_name "$a")"
      if [[ -n "$uw" ]]; then
        echo "  $a"
        echo "      user_name: ${uw%% *}   workspace: ${uw##* }"
      else
        echo "  $a   (user_name/workspace: confirm with Namazu)"
      fi
    done < <(tr ',' '\n' <<< "$agents")
  else
    echo "TRUSTED PRINCIPALS: NONE — the role's trust is an explicit deny"
    echo "for every principal (fail-closed start). Add principals"
    echo "(menu option 2) and re-send this report."
  fi

  echo
  echo "ROLE (what the agent assumes — becomes the consume_role_arn):"
  echo "  $(ticket_role_arn)"
  if [[ -n "$auser" && "$auser" != "None" ]]; then
    echo "      assume must present: SourceIdentity \"$auser\" + the external ID"
  else
    echo "      authorized user UNSET — set it (set authorized-user=NAME)
      before sending; the trust stays deny-all until it and a
      principal both exist"
  fi

  echo
  echo "CONTRACT ENTRIES (merge verbatim into the workspace agent_apn block)"
  echo
  local -a entries=()
  # One role, one AuthorizedUser — an entry per runner principal, each
  # pairing the role with that workspace. No principals yet = no entries:
  # the note below says so.
  rarn="$(ticket_role_arn)"
  if [[ -n "$agents" ]]; then
    while IFS= read -r a; do
      [[ -n "$a" ]] || continue
      uw="$(runner_user_name "$a")"
      if [[ -n "$uw" ]]; then
        entries+=("$(ticket_entry "workspace ${uw##* } — runner ${a##*/}" "$rarn" "${uw%% *}" "$auser")")
      else
        entries+=("$(ticket_entry "runner ${a##*/} (confirm the workspace with Namazu)" "$rarn" "" "$auser")")
      fi
    done < <(tr ',' '\n' <<< "$agents")
  fi
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "  (no contract entries yet — nothing to wire until principals"
    echo "   are added (option 2); the external ID above is decided and"
    echo "   waiting, and the role ARN is in the ROLES section)"
  fi
  printf '%s\n\n' ${entries[@]+"${entries[@]}"}

  echo "CAPABILITY GATES (advertised as tags on each role; the agent reads"
  echo "them at session start and fails fast on a denial):"
  g="$(snap_param CatalogPin)";               echo "  selling catalog:      ${g:-<unpinned>}"
  g="$(snap_param BenefitsCatalogPin)";       echo "  funding catalog:      ${g:-<no funding grant in this template>}"
  g="$(snap_param EnableOutboundEngagement)"; echo "  outbound engagement:  ${g:-<not a knob in this template>}"
  g="$(snap_param EnableAllianceConnections)";echo "  alliance connections: ${g:-<not a knob in this template>}"
  echo
  local spin; spin="$(snap_param EnforceSessionName)"
  echo "session-name pin: ${spin:-false}"
  echo "$bar"
}

confirm() { # $1 = question; returns 0 on yes
  local reply=""
  read -r -p "$1 [y/N]: " reply || true
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" ]]
}

# True when the stack exists and is not mid-operation; prints the reason
# and returns 1 when an add/remove can't proceed. Takes the snapshot the
# action will read from.
updatable_stack() {
  snapshot_stack
  local status
  status="$(snap_status)"
  if [[ -z "$status" ]]; then
    echo "no stack $STACK_NAME yet — nothing to do (option 1 creates it)"
    return 1
  fi
  case "$status" in
    ROLLBACK_COMPLETE)
      echo "stack $STACK_NAME is in ROLLBACK_COMPLETE (a failed create) — option 1 can delete and recreate it"
      return 1 ;;
    *_IN_PROGRESS)
      echo "stack $STACK_NAME is mid-operation ($status) — wait for it to finish, then retry"
      return 1 ;;
  esac
}

# ---- principal list helpers --------------------------------------------------
# The principal list IS the access: the trust allows exactly these
# runner ARNs (constructed from <user_name>=<workspace-id> pairs) and
# nothing else. Empty list = the role authorizes nobody.

# Current principals from the snapshot, one per line, as constructed
# ARNs (empty output = none).
current_principals() {
  [[ -n "$SNAP_DIR" ]] || snapshot_stack
  local v
  v="$(snap_param AgentRoleArns)"
  [[ -z "$v" || "$v" == "None" ]] && return 0
  tr ',' '\n' <<< "$v" | sed '/^$/d'
}

# One principal, rendered for display: the decoded pair when it follows
# the runner naming convention, else the raw ARN.
render_principal() { # $1 = ARN
  local uw
  uw="$(runner_user_name "$1")"
  if [[ -n "$uw" ]]; then
    echo "  $1"
    echo "      user_name: ${uw%% *}   workspace: ${uw##* }"
  else
    echo "  $1   (user_name/workspace: confirm with Namazu)"
  fi
}

list_principals() {
  local a n=0
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    n=$((n+1))
    render_principal "$a"
  done < <(current_principals)
  [[ "$n" -eq 0 ]] && echo "  (none — the role's trust denies everyone; option 2 adds principals)"
}

# Validate <user_name>=<workspace-id> input (comma-separated) and echo
# the constructed ARNs, one per line. Dies on any invalid entry.
# $1 = existing principals (comma-joined ARNs) for duplicate checks.
parse_principal_pairs() { # $1 = prompt input, $2 = existing ARNs
  local pair un ws seen_ws="" existing="${2:-}"
  local -a ws_pairs=()
  IFS=',' read -ra ws_pairs <<< "$1"
  for pair in ${ws_pairs[@]+"${ws_pairs[@]}"}; do
    [[ -n "$pair" ]] || continue
    un="${pair%%=*}"
    ws="${pair#*=}"
    [[ "$pair" == *=* && -n "$un" && "$un" != "$pair" ]] \
      || die "each principal must be <user_name>=<workspace-id>: $pair"
    [[ "$un" =~ $UNAME_RE ]] \
      || die "user_name '$un': 2-20 characters, letters/digits/_+=,.@- only (20 is the runner-name budget on the Namazu side)"
    [[ "$ws" =~ $WS_RE ]] \
      || die "workspace id '$ws': must be the 24-hex id shown for your instance in Namazu Cloud"
    [[ ",$seen_ws," != *",$ws,"* ]] \
      || die "workspace $ws entered twice — one runner per workspace"
    local arn="arn:aws:iam::${NAMAZU_ACCOUNT}:role/cosell-agent-${un}-${ws}"
    [[ ",$existing," != *",$arn,"* ]] \
      || die "principal already authorized: $arn"
    seen_ws="${seen_ws:+$seen_ws,}$ws"
    echo "$arn"
  done
}

# The add operation: just adds. Prompt for pairs, merge into the list,
# redeploy.
add_principals() {
  updatable_stack || return 1
  local auser
  auser="$(snap_param AuthorizedUser)"
  if [[ -z "$auser" || "$auser" == "None" ]]; then
    say "the authorized user is not set yet — the trust's Allow branch
  needs BOTH it and the principals, and until the attribution exists,
  adding principals changes nothing (CloudFormation renders the exact
  same deny-all trust, so it will not even record the update).
  set it first:   ./manage-access.sh set authorized-user=NAME"
    return 1
  fi
  local existing joined input
  existing="$(current_principals | paste -sd, -)"
  say "current principals:"
  list_principals
  say "principal to add:
  the agents' runner roles — one per Namazu Cloud workspace, named
      arn:aws:iam::${NAMAZU_ACCOUNT}:role/cosell-agent-<user_name>-<workspace-id>
  Give the workspace id and the user_name its runner should carry:
  your choice, anything IAM-compliant — we recommend it match your
  own company username convention. Namazu uses both verbatim; nothing
  is renamed on either side.
  format: <user_name>=<workspace-id>, comma-separated; the user_name
  is 2-20 characters (letters/digits/_+=,.@-), the workspace id is
  the 24-hex id shown for your instance in Namazu Cloud."
  input=""
  read -r -p "workspace pairs to authorize (blank: cancel): " input || true
  [[ -n "$input" ]] || { echo "aborted"; return 0; }
  local -a new_arns=() all_arns=() a
  while IFS= read -r a; do
    [[ -n "$a" ]] && new_arns+=("$a")
  done < <(parse_principal_pairs "$input" "$existing")
  [[ ${#new_arns[@]} -gt 0 ]] || die "no valid principals given"
  while IFS= read -r a; do all_arns+=("$a"); done < <(current_principals)
  for a in ${new_arns[@]+"${new_arns[@]}"}; do all_arns+=("$a"); done
  joined="$(printf '%s\n' ${all_arns[@]+"${all_arns[@]}"} | paste -sd, -)"
  say "principals after this change:"
  local p
  for p in ${all_arns[@]+"${all_arns[@]}"}; do render_principal "$p"; done
  confirm "apply to $STACK_NAME?" || { echo "aborted"; return 0; }
  if deploy_with_overrides "AgentRoleArns=$joined" \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]]; then
    say "done. the trust now allows exactly the principals above — every one still needs the SourceIdentity + external ID to actually assume."
  else
    echo "deploy failed"; events_hint; return 1
  fi
}

# The remove operation: just removes. Pick from the list, drop it,
# redeploy.
remove_principals() {
  updatable_stack || return 1
  local -a arns=()
  local a n=0 pick
  while IFS= read -r a; do
    [[ -n "$a" ]] && arns+=("$a")
  done < <(current_principals)
  [[ ${#arns[@]} -gt 0 ]] || { say "no principals authorized — the role's trust already denies everyone."; return 0; }
  say "authorized principals:"
  local i=1
  for a in ${arns[@]+"${arns[@]}"}; do
    echo "  $i) $(render_principal "$a" | head -1)"
    local uw; uw="$(runner_user_name "$a")"
    [[ -n "$uw" ]] && echo "      user_name: ${uw%% *}   workspace: ${uw##* }"
    i=$((i+1))
  done
  read -r -p "remove which (number): " pick || true
  [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le ${#arns[@]} ]] || die "invalid selection"
  local victim="${arns[$((pick-1))]}"
  local -a kept=()
  for a in ${arns[@]+"${arns[@]}"}; do [[ "$a" != "$victim" ]] && kept+=("$a"); done
  if [[ ${#kept[@]} -eq 0 ]]; then
    say "removing the last principal — the role's trust returns to the
  explicit deny (nobody authorized). The role and its parameters stay."
    if ! confirm "remove it?"; then echo "aborted"; return 0; fi
  else
    say "principals after this change:"
    for a in ${kept[@]+"${kept[@]}"}; do render_principal "$a"; done
    confirm "apply to $STACK_NAME?" || { echo "aborted"; return 0; }
  fi
  local joined
  joined="$(printf '%s\n' ${kept[@]+"${kept[@]}"} | paste -sd, -)"
  if deploy_with_overrides "AgentRoleArns=$joined" \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]]; then
    say "done. '$victim' can no longer assume; IAM takes effect immediately."
    say "tell Namazu to drop the contract entry that names it."
  else
    echo "deploy failed"; events_hint; return 1
  fi
}

# ---- preflight --------------------------------------------------------------
banner
account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "could not authenticate to AWS (aws sts get-caller-identity failed). Configure credentials for the account linked to your Partner Central account, then retry."
region="${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo '(default)')}"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE (run this from the repo checkout)"
echo "aws account: $account   region: $region"

# ---- actions ----------------------------------------------------------------
# Option 1 — first-time setup (also the recreate path for a failed create).
create_stack() {
  local overrides=() extid status=""
  snapshot_stack
  status="$(snap_status)"
  if [[ -n "$status" ]]; then
    if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
      say "stack $STACK_NAME is in ROLLBACK_COMPLETE (a failed create) — it can only be deleted, not updated."
      confirm "delete it and recreate fresh?" || die "aborted (delete it manually, then rerun)"
      if aws cloudformation delete-stack --stack-name "$STACK_NAME" \
         && aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
        :
      else
        echo "delete failed"; events_hint; return 1
      fi
      snapshot_stack # the deletion changed everything
    else
      say "stack $STACK_NAME already exists (status: $status) — nothing to create."
      echo "use option 2 to add principals to it."
      return 0
    fi
  fi

  # ONE SHOT: the stack + the empty role, nothing else asked. The
  # external ID is the one required decision — generated unless
  # --external-id supplied it — and everything else takes its
  # fail-safe template default (Sandbox catalog, no session pin, no
  # authorized user, no principals). The two access decisions (the
  # authorized user and the principals) are wired AFTER create.
  local extid
  extid="${EXTERNAL_ID:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)}"
  [[ "$extid" =~ $EXTID_RE ]] || die "invalid --external-id (at least 2 characters; letters/digits/_+=,.@- only)"

  say "one-shot create:
  stack:      $STACK_NAME
  role:       exists immediately, trust = explicit deny (nobody authorized)
  external ID: $extid  (generated${EXTERNAL_ID:+, from --external-id})
  catalog:    Sandbox (the fail-safe default; flip with options 5/6)
  after create: set the authorized user (set authorized-user=NAME) and
                add principals (option 2) — access exists only when both
                are set."
  confirm "create it?" || { echo "aborted"; return 0; }

  overrides=("ExternalId=$extid")
  aws cloudformation deploy \
    --template-file "$TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "${overrides[@]}" \
    || { echo "deploy failed"; events_hint; return 1; }

  snapshot_stack # the create added outputs
  say "done. stack status: $(snap_status)."
  print_ticket_report
}

list_state() {
  snapshot_stack
  local status auser
  status="$(snap_status)"
  [[ -n "$status" ]] || { echo "no stack $STACK_NAME yet — nothing to list (option 1 creates it)"; return 0; }
  echo "stack: $STACK_NAME ($status)"
  local catalog bencatalog outbound alliance extid sesspin
  catalog="$(snap_param CatalogPin)"
  bencatalog="$(snap_param BenefitsCatalogPin)"
  outbound="$(snap_param EnableOutboundEngagement)"
  alliance="$(snap_param EnableAllianceConnections)"
  extid="$(snap_param ExternalId)"
  sesspin="$(snap_param EnforceSessionName)"
  auser="$(snap_param AuthorizedUser)"
  say "role:"
  echo "  ARN: $(ticket_role_arn)"
  if [[ -n "$auser" && "$auser" != "None" ]]; then
    echo "  authorized user: $auser"
  else
    echo "  authorized user: <unset — set with: ./manage-access.sh set authorized-user=NAME>"
  fi
  say "principals (the only thing that may assume; change: options 2/4):"
  list_principals
  say "IAM gates in force (change: options 5-8):"
  say "  selling catalog:   ${catalog:-<unmanaged>}"
  say "  funding catalog:   ${bencatalog:-<no funding grant in this stack template>}"
  say "  outbound engagement [partner-initiated co-sell]: ${outbound:-<not a knob in this stack template>}"
  say "  alliance connections [partner-to-partner]:       ${alliance:-<not a knob in this stack template>}"
  say "  external ID: ${extid:+set}${extid:-none}   session-name pin: ${sesspin:-false}"
}

# change_pin — show, confirm, and redeploy one stack parameter. The
# generic gate-changing flow: every other parameter is preserved.
change_pin() {
  updatable_stack || return 1
  local key="$1" label="$2" choices="$3"
  local cur
  cur="$(snap_param "$key")"
  if [[ -z "$cur" ]]; then
    say "this stack's template doesn't carry $key — redeploy with the current template first."
    return 1
  fi
  say "current $label: $cur"
  say "  allowed: $choices"
  confirm "change it?" || { echo "aborted"; return 0; }
  local v=""
  read -r -p "new value, one of: $choices : " v || true
  local ok=0
  for c in $choices; do
    [[ "$v" == "$c" ]] && ok=1
  done
  [[ "$ok" == 1 ]] || die "value must be one of: $choices"
  [[ "$v" == "$cur" ]] && { say "already $v — nothing to do"; return 0; }
  confirm "redeploy $STACK_NAME with $key=$v?" || { echo "aborted"; return 0; }
  if deploy_with_overrides "$key=$v" \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]]; then
    local newval
    newval="$(snap_param "$key")"
    say "done. $label is now: $newval"
    say "IAM re-evaluates per request; a live agent session picks this up at its next credential refresh, about 1h. Update the agent-side hint to match. IAM decides either way."
    say "the gates changed — reprint the ticket report (option 9) before contacting Namazu: its capability gates reflect the new state."
  else
    echo "deploy failed"; events_hint; return 1
  fi
}

change_selling_catalog() {
  change_pin CatalogPin "selling catalog [partnercentral-selling]" "Sandbox AWS Both"
}

change_funding_catalog() {
  change_pin BenefitsCatalogPin "funding catalog [partnercentral-benefits]" "Sandbox AWS Both"
}

change_outbound_engagement() {
  change_pin EnableOutboundEngagement "outbound engagement [partner-initiated co-sell]" "true false"
}

change_alliance_connections() {
  change_pin EnableAllianceConnections "alliance connections [partner-to-partner]" "true false"
}

delete_stack() {
  stack_exists || { echo "no stack $STACK_NAME — nothing to delete"; return 0; }
  confirm "delete stack $STACK_NAME (the role goes with it)?" || { echo "aborted"; return 0; }
  if aws cloudformation delete-stack --stack-name "$STACK_NAME" \
     && aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
    say "stack deleted — the role and its trust are gone; all access stops immediately"
  else
    echo "delete failed"; events_hint; return 1
  fi
}

# Detailed, task-by-task help (menu option h).
show_help() {
  cat <<'EOF'

how this tool works, task by step
=================================

THE MODEL
  One CloudFormation stack, one IAM role. Access is exactly one thing:
  the principal list. Create (option 1) makes the role with its trust
  authorizing NOBODY — an explicit deny for every principal. Add a
  principal (option 2) and the Namazu agent's runner role for that
  workspace may assume — still only with the right SourceIdentity and
  external ID. Remove one (option 4) and it cannot, immediately.
  Delete the stack (option 0) and the role goes with it. There is no
  account-root trust anywhere: the empty state is fail-closed by
  construction.

1) CREATE THE ACCESS STACK (one shot)
   step 1  make sure you are authenticated to the AWS account linked
           to your Partner Central account (shown in the header).
   step 2  confirm. The external ID is generated (or pass
           --external-id up front); the catalog defaults to Sandbox;
           the authorized user and the principals are NOT asked — the
           stack and the empty role exist the moment this finishes,
           with the trust an explicit deny for every principal.
   step 3  the script prints the ticket report: hand the external ID
           and the role ARN to your Namazu contact when ready.

2) ADD PRINCIPALS
2) ADD PRINCIPALS
   step 1  give <user_name>=<workspace-id> pairs, comma-separated
           (see FIELD REFERENCE). The script constructs each runner
           ARN — you never paste an ARN — and shows the full list
           after the change.
   step 2  confirm. The stack is UPDATED; every other parameter is
           re-passed unchanged. The principal can assume immediately
           (with the SourceIdentity + external ID).

3) LIST THE STATE
   The stack status, the role ARN, the authorized user (or the unset
   state), the principal list (or the nobody-authorized state), the
   catalog pins, the motion toggles, and the external ID /
   session-pin state. Read-only.

4) REMOVE A PRINCIPAL
   step 1  pick the principal by number.
   step 2  confirm. The trust drops it; the principal cannot assume
           immediately. Removing the last one returns the role to the
           explicit deny — the role itself stays, ready to authorize
           the next principal.

5) CHANGE THE SELLING CATALOG
   partnercentral-selling — opportunities, invitations, solutions.
   Enforced by IAM on the role ('Sandbox' for AWS's isolated test
   catalog, 'AWS' production, 'Both'; there is no unpinned option).
   Every other parameter is preserved.

6) CHANGE THE FUNDING CATALOG
   partnercentral-benefits — funding applications, a real-money ask,
   so its pin is SEPARATE from the selling pin and defaults to
   Sandbox: enabling production selling never silently enables
   production funding. Same three-way choice, same enforcement.

7) TOGGLE OUTBOUND ENGAGEMENT
   on:  engagements + engagement invitations to bring AWS sellers
        onto partner-originated opportunities, the
        engagement<->opportunity task machinery (including
        converting an accepted invitation into an opportunity),
        prospecting, and resource snapshots.
   off: the role stays receive-only. Default. Enforced by IAM
        (explicit Deny on the outbound action set when off).

8) TOGGLE ALLIANCE CONNECTIONS
   on:  the Account API's partner-to-partner motions: connections
        + connection invitations (alliance-led co-sell), partner
        reads, alliance-lead contact.
   off: default. Enforced by IAM the same way.

9) PRINT THE TICKET REPORT
   Everything to send Namazu, copy-paste ready: account/region/stack,
   the Namazu Cloud workspace(s) the ticket wires, the external ID,
   the trusted principals (or the nobody-authorized state), the role
   ARN with the SourceIdentity it requires, the contract entries
   verbatim in the agent_apn shape (consume_role_arn, user_name,
   source_identity, external_id, catalog), and the capability gates
   in force. Read-only — run it anytime; it always reflects the live
   stack.

0) DELETE THE ACCESS STACK
   Deletes the stack AND the role — there is no retain; all access
   stops immediately. Reversible only by recreating (option 1) with a
   fresh external ID and re-adding principals.

FIELD REFERENCE
  authorized   2-64 characters, letters/digits/_+=,.@-; the person the
  user         role is attributed to — the role's AuthorizedUser tag
               and the sts:SourceIdentity the agent must present. NOT
               asked at create: set it after (set authorized-user=NAME);
               the trust's Allow branch needs it AND a principal.
  principal    <user_name>=<workspace-id> — the pair that names one
  pair         runner role: arn:aws:iam::308044622771:role/
               cosell-agent-<user_name>-<workspace-id>. The user_name
               is YOUR choice, anything IAM-compliant up to 20
               characters (letters/digits/_+=,.@-); we recommend it
               match your own company username convention. The
               workspace id is the 24-hex id shown for your instance
               in Namazu Cloud. Options 2/4 add and remove them; the
               trust allows exactly the constructed ARNs, nothing
               else.
  external ID  REQUIRED shared secret for assume-role (2+ chars,
               same charset) — confused-deputy protection. The create
               flow generates a random one by default or takes yours;
               share it with your Namazu contact, who wires it into
               the deployment contract (both sides must match, or
               every assume is denied).
  catalogs     'Sandbox', 'AWS', or 'Both' for each of selling and
               funding (see options 5 and 6); enforced by IAM.
  motions      'true'/'false' toggles for outbound engagement
               (option 7) and alliance connections (option 8).
  session pin  forces sessions to be named
               '<authorized-user>-session'; set at create time.
               Enable only if the Namazu side configures session
               names.

CLI FLAGS
  --stack-name    manage a different stack (default
                  namazu-cosell-manager) — e.g. separate stacks per
                  environment.
  --external-id   supply the external ID at the one-shot create
                  instead of generating one.
  --region      region for the AWS calls (default: your CLI config)
EOF
}

# ---- gate registry -----------------------------------------------------------
gate_param() {
  case "$1" in
    selling)         echo "CatalogPin" ;;
    funding)         echo "BenefitsCatalogPin" ;;
    outbound)        echo "EnableOutboundEngagement" ;;
    alliance)        echo "EnableAllianceConnections" ;;
    session-pin)     echo "EnforceSessionName" ;;
    authorized-user) echo "AuthorizedUser" ;;
    *) echo "" ;;
  esac
}

gate_label() {
  case "$1" in
    selling)         echo "selling catalog" ;;
    funding)         echo "funding catalog" ;;
    outbound)        echo "outbound engagement [partner-initiated co-sell]" ;;
    alliance)        echo "alliance connections [partner-to-partner]" ;;
    session-pin)     echo "session-name pin" ;;
    authorized-user) echo "authorized user [SourceIdentity attribution]" ;;
    *) echo "$1" ;;
  esac
}

validate_gate() {
  local key="$1" val="$2"
  case "$key" in
    selling|funding)
      case "$val" in Sandbox|AWS|Both) return 0 ;; esac ;;
    outbound|alliance|session-pin)
      case "$val" in true|false) return 0 ;; esac ;;
    authorized-user)
      [[ "$val" =~ ^[A-Za-z0-9_+=,.@-]{2,64}$ ]] && return 0 ;;
  esac
  return 1
}

# ---- ANSI --------------------------------------------------------------------
C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'

gate_dot() {
  local v="${2:-}"
  case "$v" in
    Both|true)  echo "${C_G}●${C_0} $v" ;;
    Sandbox)    echo "${C_Y}●${C_0} $v" ;;
    false|"")   echo "${C_D}○${C_0} ${v:-off}" ;;
    *)          echo "${C_G}●${C_0} $v" ;;
  esac
}

drift_dot() {
  case "$1" in
    IN_SYNC)     echo "${C_G}●${C_0} in-sync" ;;
    DRIFTED)     echo "${C_R}●${C_0} DRIFTED" ;;
    "")          echo "${C_D}●${C_0} never checked" ;;
    *)           echo "${C_Y}●${C_0} $1" ;;
  esac
}

# ---- per-stack state fetch ---------------------------------------------------
# ONE describe-stacks round trip per stack; everything comes out on stdout
# with prefixes (S: status, D: drift, P:<Key>=<Value>) — no globals, so the
# parallel dashboard fetches cannot cross-contaminate.
fetch_stack_state() { # $1 = stack name
  local raw
  raw="$(aws cloudformation describe-stacks --stack-name "$1" --output json 2>/dev/null)" || { echo "MISSING"; return 1; }
  printf '%s' "$raw" | python3 -c "
import json, sys
d = json.load(sys.stdin)['Stacks'][0]
print('S:' + d.get('StackStatus', ''))
print('D:' + (d.get('StackDriftStatus') or ''))
for p in d.get('Parameters', []):
    print('P:' + p['ParameterKey'] + '=' + p['ParameterValue'])
" 2>/dev/null
}

field_of() { # $1 = fetched lines, $2 = prefix — $1 is an ARGUMENT, feed it to awk
  awk -v pre="$2" 'index($0, pre) == 1 { sub("^" pre, ""); print; exit }' <<< "$1"
}

param_of() { # $1 = fetched lines, $2 = key
  awk -v pre="P:" -v k="$2" 'index($0, pre k "=") == 1 { sub("^" pre k "=", ""); print; exit }' <<< "$1"
}

render_card_from() { # $1 = state file, $2 = stack name
  local stack="$2" fetched
  fetched="$(cat "$1")"
  if [[ -z "$fetched" ]]; then return 1; fi
  local status drift selling funding outbound alliance extid sesspin agents auser
  status="$(field_of "$fetched" "S:")"
  drift="$(field_of "$fetched" "D:")"
  selling="$(param_of "$fetched" CatalogPin)"
  funding="$(param_of "$fetched" BenefitsCatalogPin)"
  outbound="$(param_of "$fetched" EnableOutboundEngagement)"
  alliance="$(param_of "$fetched" EnableAllianceConnections)"
  extid="$(param_of "$fetched" ExternalId)"
  sesspin="$(param_of "$fetched" EnforceSessionName)"
  agents="$(param_of "$fetched" AgentRoleArns)"
  auser="$(param_of "$fetched" AuthorizedUser)"
  echo "┌─ $stack — the agent deployment's gates [consume_role_arn] ──"
  echo "│  status: $status    drift: $(drift_dot "$drift")"
  echo "│  selling  $(gate_dot selling "$selling")   funding  $(gate_dot funding "$funding")"
  echo "│  outbound $(gate_dot outbound "$outbound")   alliance $(gate_dot alliance "$alliance")"
  echo "│  external-id: ${extid:+set}${extid:-none}    session-pin: ${sesspin:-false}"
  [[ -n "$auser" ]] && echo "│  authorized user: $auser"
  [[ -z "$auser" ]] && echo "│  ${C_Y}authorized user UNSET — trust is deny-all${C_0}"
  [[ -n "$agents" ]] && { echo "│  principals:"; echo "$agents" | tr ',' '\n' | sed 's/^/│    /'; }
  [[ -z "$agents" ]] && echo "│  ${C_Y}principals: NONE — trust is deny-all${C_0}"
  echo "└───────────────────────────────────────────────────────"
}

render_dashboard() {
  # One card: the stack being managed. There is no hardcoded "other" —
  # the script manages exactly the stack --stack-name points at, and a
  # not-created stack gets a one-line hint, never a card box.
  local fetched
  fetched="$(fetch_stack_state "$STACK_NAME")"
  if [[ "$fetched" == "MISSING" || -z "$fetched" ]]; then
    echo "${C_D}· $STACK_NAME: not created${C_0}"
    return 0
  fi
  render_card_from <(printf '%s\n' "$fetched") "$STACK_NAME"
}

# ---- commands ----------------------------------------------------------------
cmd_status() {
  if [[ "$JSON" == 1 ]]; then
    local fetched
    fetched="$(fetch_stack_state "$STACK_NAME")"
    if [[ "$fetched" == "MISSING" || -z "$fetched" ]]; then
      echo "{\"stack\": \"$STACK_NAME\", \"missing\": true}"
      return 0
    fi
    echo "{"
    echo "  \"stack\": \"$STACK_NAME\","
    echo "  \"status\": \"$(field_of "$fetched" "S:")\","
    echo "  \"drift\": \"$(field_of "$fetched" "D:")\","
    echo "  \"selling\": \"$(param_of "$fetched" CatalogPin)\","
    echo "  \"funding\": \"$(param_of "$fetched" BenefitsCatalogPin)\","
    echo "  \"outbound\": \"$(param_of "$fetched" EnableOutboundEngagement)\","
    echo "  \"alliance\": \"$(param_of "$fetched" EnableAllianceConnections)\","
    echo "  \"external_id\": \"$(param_of "$fetched" ExternalId)\","
    echo "  \"session_pin\": \"$(param_of "$fetched" EnforceSessionName)\","
    echo "  \"authorized_user\": \"$(param_of "$fetched" AuthorizedUser)\","
    echo "  \"principals\": \"$(param_of "$fetched" AgentRoleArns)\""
    echo "}"
    return 0
  fi
  render_dashboard
}

cmd_drift() {
  local s="$STACK_NAME" id res
  id="$(aws cloudformation detect-stack-drift --stack-name "$s" --query 'StackDriftDetectionId' --output text 2>/dev/null)"
  if [[ -z "$id" || "$id" == "None" ]]; then echo "$s: detection failed"; return 1; fi
  printf '%s: detecting…' "$s"
  for i in $(seq 1 20); do
    sleep 5
    res="$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$id" --query 'StackDriftDetectionStatus' --output text 2>/dev/null)"
    case "$res" in DETECTION_COMPLETE|DETECTION_FAILED) break;; esac
  done
  printf '\r%s: ' "$s"
  aws cloudformation describe-stack-resource-drifts --stack-name "$s"     --query 'StackResourceDrifts[0].StackResourceDriftStatus' --output text 2>/dev/null || echo "n/a"
}

cmd_set() {
  local -a pairs=()
  if [[ $# -ge 2 && "$1" != *=* ]]; then
    pairs+=("$1=$2"); shift 2
  fi
  local a
  for a in "$@"; do
    [[ "$a" == "--yes" || "$a" == "--json" ]] && continue
    [[ "$a" == *=* ]] || die "set: expected KEY=VALUE pairs (e.g. manage-access set selling=Both)"
    pairs+=("$a")
  done
  [[ ${#pairs[@]} -ge 1 ]] || die "set: nothing to change (e.g. manage-access set selling=Sandbox)"

  updatable_stack || return 1
  local -a overrides=()
  local pair key val pkey cur
  local -a plan=()
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    key="${pair%%=*}"; val="${pair#*=}"
    pkey="$(gate_param "$key")"
    [[ -n "$pkey" ]] || die "unknown gate: $key [known: selling funding outbound alliance session-pin authorized-user]"
    validate_gate "$key" "$val" || die "invalid value for $key: $val"
    cur="$(snap_param "$pkey")"
    overrides+=("$pkey=$val")
    if [[ "$val" == "$cur" ]]; then
      plan+=("  $(gate_label "$key"): $cur        [unchanged]")
    else
      plan+=("  $(gate_label "$key"): ${cur:-<unset>} -> $val")
    fi
  done

  say "plan:"
  local l changed=0
  for l in ${plan[@]+"${plan[@]}"}; do
    echo "  $l"
    [[ "$l" == *"[unchanged]" ]] || changed=1
  done
  if [[ "$changed" == 0 ]]; then
    say "nothing to change — done."
    return 0
  fi
  if [[ "$YES" == 1 ]]; then
    echo "--yes: applying without confirmation"
  else
    confirm "apply to $STACK_NAME?" || { echo "aborted"; return 0; }
  fi
  if deploy_with_overrides ${overrides[@]+"${overrides[@]}"} \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]]; then
    say "done. gates updated — IAM re-evaluates per request; the capability tags update with the policy, so the agent discovers the new envelope on its next session."
  else
    echo "deploy failed"; events_hint; return 1
  fi
}

# ---- commands ---------------------------------------------------------------
case "$COMMAND" in
  "")         : ;;
  status)     cmd_status; exit 0 ;;
  drift)      cmd_drift; exit 0 ;;
  set)        cmd_set "$@"; exit $? ;;
  ticket)     print_ticket_report; exit 0 ;;
  delete)     delete_stack; exit 0 ;;
  help)       show_help; exit 0 ;;
  menu)       : ;;
  *)          die "unknown command: $COMMAND (commands: status set drift ticket delete menu help; or run with no command for the menu)" ;;
esac

interactive_menu() {
choice=""
while true; do
  echo
  echo "${C_B}Namazu co-selling agent — access manager${C_0}"
  render_dashboard
  echo
  echo "  1) Create the access stack (the role exists; nobody authorized yet)."
  echo "  2) Add principals (trust the agents' runner roles)."
  echo "  3) List the role, principals, and the IAM gates in force."
  echo "  4) Remove a principal."
  echo "  5) Change the selling catalog (Sandbox / AWS / Both)."
  echo "  6) Change the funding catalog (Sandbox / AWS / Both)."
  echo "  7) Toggle outbound engagement (partner-initiated co-sell)."
  echo "  8) Toggle alliance connections (partner-to-partner)."
  echo "  9) Print the ticket report (everything to send Namazu)."
  echo "  0) Delete the access stack entirely."
  echo "  h) Help — what each option does, step by step."
  echo "  q) Quit."
  read -r -p "> " choice || { echo; exit 0; }
  case "$choice" in
    1) create_stack ;;
    2) add_principals ;;
    3) list_state ;;
    4) remove_principals ;;
    5) change_selling_catalog ;;
    6) change_funding_catalog ;;
    7) change_outbound_engagement ;;
    8) change_alliance_connections ;;
    9) print_ticket_report ;;
    0) delete_stack ;;
    h|H) show_help ;;
    q|Q) exit 0 ;;
    *) echo "Invalid choice — please enter 1–9, 0, h, or q." ;;
  esac
done
}
interactive_menu
