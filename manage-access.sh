#!/usr/bin/env bash
# manage-access.sh — interactive manager for the Namazu co-selling
# agent's customer-side access. THE MODEL: one stack, ONE well-known
# role (Namazu-CoSell-Opportunity-Manager), created and destroyed by the
# stack, assumable by ZERO OR MORE principals from Namazu's account.
# Create (option 1) is ONE SHOT: it needs nothing but the external ID
# (generated unless --external-id) and deploys the role with its trust
# authorizing NOBODY. Adding a user (option 2) asks two questions, one
# at a time: the identifier — the user's org-internal notation
# (recommended: first initial + last name, e.g. jsmith), baked into the
# runner role name to be provisioned by Namazu Studios
# (cosell-agent-<identifier>-<workspace>, their ONLY principal) AND the
# sts:SourceIdentity their sessions present — and their workspace id in
# Namazu Cloud. One Allow statement per user, composed by this script
# into the role's trust. Removing a user (option 4) drops theirs.
# Deleting the stack destroys the role. Gate flips (options 5-8)
# round it out; after every add the report is the exact configuration
# Namazu needs.
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
# ONE template, ONE model: a stack, a well-known role, a user list.
# Create (option 1) is one shot — it needs nothing but the ExternalId
# (generated unless --external-id) and deploys the role with its trust
# authorizing NOBODY. Users (options 2/4) are the whole access model:
# each entry <identifier>|<workspace-id> adds one trust statement — the
# runner to be provisioned by Namazu Studios for that workspace, with
# the identifier (their org-internal notation, e.g. jsmith) as the
# SourceIdentity. The script composes the trust JSON from the list;
# zero users = deny-all.
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
# capped at 20 characters — the Namazu Studios provisioning truncates
# beyond 20
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
nobody), add/remove users (two questions per user — their identifier
(org-internal notation, e.g. jsmith: baked into the runner role name
to be provisioned by Namazu Studios AND the SourceIdentity they
present) and their workspace id — one trust statement each), flip
the capability gates, print the ticket report to send Namazu, or
delete the stack (the role goes with it). In the menu, 'h' shows a detailed help.

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
# may still be empty — an empty Users list is a real state, not an
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
  # Trust sync: the TrustPolicy parameter is ALWAYS recomposed from the
  # resolved Users list + the resolved session-name pin, so the trust
  # can never drift from the user list (add/remove update it; a
  # session-pin flip re-renders every statement; every other update
  # re-composes the identical trust). NOTE the single-dash lookups: an
  # EMPTY Users override (remove-the-last-user) is a real value, not a
  # fallback trigger.
  local r_users r_pin
  r_users="${ov[Users]-$(snap_param Users)}"
  r_pin="${ov[EnforceSessionName]-$(snap_param EnforceSessionName)}"
  ov[TrustPolicy]="$(compose_trust "$r_users" "$r_pin")"
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
  # Surface the actual error, not just the fact of it: the newest
  # FAILED-resource reason from the stack's events. The trailing
  # (RequestToken: …)/(HandlerErrorCode: …) metadata is trimmed — the
  # message is what the operator needs.
  local reason
  reason="$(aws cloudformation describe-stack-events --stack-name "$STACK_NAME" \
    --query 'sort_by(StackEvents, &Timestamp)[?ResourceStatus==`UPDATE_FAILED` || ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_ROLLBACK_FAILED` || ResourceStatus==`ROLLBACK_FAILED`].ResourceStatusReason' \
    --output text 2>/dev/null | tail -1)"
  reason="${reason%% (RequestToken*}"
  reason="${reason%% (HandlerErrorCode*}"
  if [[ -n "$reason" && "$reason" != "None" ]]; then
    say "the error from CloudFormation:"
    printf '%s\n' "$reason" | fold -s -w 74 | sed 's/^/  /'
  else
    say "no failure reason found in the stack events (the error above,
  if any, is from the deploy command itself — e.g. a rejected
  changeset, which does not write stack events)."
  fi
  echo "  full history: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region <your-region>"
}

# ---- ticket report -----------------------------------------------------------
# Everything the operator needs to put into a support ticket for Namazu:
# the ExternalId secret, the trusted runner principals, every role ARN,
# and the contract entries rendered in the exact shape the Namazu
# deployment contract (the agent_apn block) carries. Read-only — built
# entirely from the snapshot, so it always reflects the live stack.
# Printed after create and after every add, so the ticket a customer
# sends is never assembled by hand.

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

print_ticket_report() {
  snapshot_stack
  local status extid
  status="$(snap_status)"
  if [[ -z "$status" ]]; then
    echo "no stack $STACK_NAME — nothing to report (option 1 creates it)"
    return 1
  fi
  extid="$(snap_param ExternalId)"
  local bar e id ws g
  bar="$(printf '%0.s─' $(seq 1 64))"

  say "$bar"
  echo "TICKET REPORT — Namazu co-selling agent access"
  echo "send this to Namazu (a support ticket works): it is everything"
  echo "they need to wire the agent deployment to the role below."
  echo "$bar"
  echo "account:  $account"
  echo "region:   $region"
  echo "stack:    $STACK_NAME ($status)"

  echo
  echo "NAMAZU CLOUD WORKSPACE(S) — the deployment(s) this ticket wires;"
  echo "each id is the workspace that user's agent runs in:"
  local n_users=0
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    n_users=$((n_users+1))
    IFS='|' read -r id ws <<< "$e"
    echo "  $ws   identifier/source identity: $id"
  done < <(current_users)
  [[ "$n_users" -eq 0 ]] && echo "  (none yet — they come with the users: option 2 adds them)"

  echo
  echo "EXTERNAL ID (secret — every assume-role must present it; any"
  echo "mismatch is a total deny):"
  echo "  ${extid:-<not set — required: redeploy with the current template>}"

  echo
  if [[ "$n_users" -gt 0 ]]; then
    echo "TRUSTED PRINCIPALS (one per user — the runner role to be"
    echo "provisioned by Namazu Studios for their workspace; each must"
    echo "present their identifier as the source identity + the external"
    echo "ID):"
    while IFS= read -r e; do
      [[ -n "$e" ]] || continue
      render_user "$e"
    done < <(current_users)
  else
    echo "TRUSTED PRINCIPALS: NONE — the role's trust is an explicit deny"
    echo "for every principal (fail-closed start). Add users"
    echo "(menu option 2) and re-send this report."
  fi

  echo
  echo "ROLE (what the agent assumes — becomes the consume_role_arn):"
  echo "  $(ticket_role_arn)"
  [[ "$n_users" -gt 0 ]] && echo "      every assume presents its user's source identity + the external ID"

  echo
  echo "CONTRACT ENTRIES (merge verbatim into the workspace agent_apn block)"
  echo
  local -a entries=()
  local rarn
  rarn="$(ticket_role_arn)"
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    IFS='|' read -r id ws <<< "$e"
    entries+=("$(ticket_entry "workspace $ws — runner $(runner_arn_of "$id" "$ws" | sed 's|.*/||')" "$rarn" "$id" "$id")")
  done < <(current_users)
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "  (no contract entries yet — nothing to wire until users are"
    echo "   added (option 2); the external ID above is decided and"
    echo "   waiting, and the role ARN is in the ROLE section)"
  fi
  printf '%s\n\n' ${entries[@]+"${entries[@]}"}

  echo "CAPABILITY GATES (advertised as tags on the role; the agent reads"
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
  if [[ "$status" == *ROLLBACK* ]]; then
    say "note: the stack is $status — the last update FAILED and rolled
  back. Anything added in that update is NOT on the stack (this is
  why users from a failed add do not show up); the stack itself is
  stable and updatable, so re-adding works."
  fi
}

# ---- user entries -------------------------------------------------------------
# A USER is one entry in the role's trust, and one line in the Users
# parameter: <identifier>|<workspace-id>. The identifier is the user's
# org-internal notation (recommended: first initial + last name, e.g.
# jsmith) and does double duty: it is baked into the runner role name
# to be provisioned by Namazu Studios (cosell-agent-<identifier>-
# <workspace> — their ONLY principal) AND it is the sts:SourceIdentity
# their sessions must present, the id both sides attribute their
# actions to. The workspace id ties it to their Namazu Cloud
# deployment. Zero users = the role authorizes nobody (deny-all).

# Current user entries from the snapshot, one per line (empty = none).
current_users() {
  [[ -n "$SNAP_DIR" ]] || snapshot_stack
  local v
  v="$(snap_param Users)"
  [[ -z "$v" || "$v" == "None" ]] && return 0
  tr ',' '\n' <<< "$v" | sed '/^$/d'
}

# The runner ARN for an entry — the expected principal in Namazu's
# account, to be provisioned by Namazu Studios with this deterministic
# name.
runner_arn_of() { # $1 = identifier, $2 = workspace
  echo "arn:aws:iam::${NAMAZU_ACCOUNT}:role/cosell-agent-$1-$2"
}

# One entry, rendered for display.
render_user() { # $1 = entry <identifier>|<workspace-id>
  local id ws
  IFS='|' read -r id ws <<< "$1"
  echo "  $(runner_arn_of "$id" "$ws")"
  echo "      identifier/source identity: $id   workspace: $ws"
}

list_users_entries() {
  local e n=0
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    n=$((n+1))
    render_user "$e"
  done < <(current_users)
  [[ "$n" -eq 0 ]] && echo "  (none — the trust denies everyone; option 2 adds users)"
}

# The complete trust policy JSON for a user list: one Allow statement
# per user (their runner as Principal; their identifier as the
# sts:SourceIdentity; the stack's ExternalId; the '<identifier>-session'
# RoleSessionName pin when $2 is true). Empty list renders the
# fail-closed deny-all.
compose_trust() { # $1 = comma-joined entries, $2 = EnforceSessionName true/false
  local joined="${1:-}" pin="${2:-false}" stmts="" first=1 e id ws arn cond stmt
  [[ "$joined" == "None" ]] && joined=""
  if [[ -z "$joined" ]]; then
    echo '{"Version":"2012-10-17","Statement":[{"Sid":"NobodyAuthorizedYet","Effect":"Deny","Principal":{"AWS":"*"},"Action":["sts:AssumeRole","sts:SetSourceIdentity"]}]}'
    return 0
  fi
  while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    IFS='|' read -r id ws <<< "$e"
    arn="$(runner_arn_of "$id" "$ws")"
    cond="{\"sts:SourceIdentity\":\"${id}\",\"sts:ExternalId\":\"$(snap_param ExternalId)\""
    [[ "$pin" == "true" ]] && cond="${cond},\"sts:RoleSessionName\":\"${id}-session\""
    cond="${cond}}"
    stmt="{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"${arn}\"},\"Action\":[\"sts:AssumeRole\",\"sts:SetSourceIdentity\"],\"Condition\":{\"StringEquals\":${cond}}}"
    [[ $first -eq 1 ]] && stmts="$stmt" || stmts="${stmts},${stmt}"
    first=0
  done < <(tr ',' '\n' <<< "$joined")
  echo "{\"Version\":\"2012-10-17\",\"Statement\":[${stmts}]}"
}

# The add operation: just adds. Two questions per user, one at a time;
# the identifier does double duty (runner-name label + SourceIdentity).
add_user() {
  updatable_stack || return 1
  local existing
  existing="$(snap_param Users)"
  [[ -z "$existing" || "$existing" == "None" ]] && existing=""
  say "current users:"
  list_users_entries

  local -a new_entries=()
  local id ws v e
  say "adding a user — two questions, one at a time. (The README carries a
  screenshot — namazu-cloud-workspace.png — showing where both values
  appear in Namazu Cloud.)

  About the identifier: it must match the runner role Namazu Studios
  provisions for that workspace — cosell-agent-<identifier>-<workspace>.
  If the workspace already has a deployment, use the identifier already
  provisioned (your Namazu contact confirms it). For a new workspace,
  pick your org-internal notation — we recommend first initial + last
  name, e.g. jsmith — and share it with Namazu via the report; they
  provision it verbatim. IAM rejects unknown principals, so a mismatch
  fails the whole update — each user is deployed separately below so a
  bad one cannot sink the rest."
  while true; do
    # 1) identifier — the org-internal notation; double duty.
    id=""
    while true; do
      read -r -p "  identifier — the label in the runner role name Namazu Studios provisions for this workspace (blank: stop): " id || break 2
      [[ -z "$id" ]] && break 2
      [[ "$id" =~ $UNAME_RE ]] && break
      echo "    invalid: 2-20 characters, letters/digits/_+=,.@- only"
    done
    # 2) workspace id — the Namazu Cloud workspace.
    ws=""
    while true; do
      read -r -p "  workspace id — the 24-hex id of their workspace in Namazu Cloud (e.g. 0a1b2c3d4e5f6a7b8c9d0e1f): " ws || break 2
      if [[ ! "$ws" =~ $WS_RE ]]; then
        echo "    invalid: exactly 24 hex characters — the id shown for their workspace in Namazu Cloud"
        continue
      fi
      local dup=0
      while IFS= read -r e; do [[ "$e" == *"|$ws" ]] && dup=1; done < <(current_users)
      for e in ${new_entries[@]+"${new_entries[@]}"}; do [[ "$e" == *"|$ws" ]] && dup=1; done
      if [[ "$dup" == 1 ]]; then
        echo "    workspace $ws already has a user — one user per workspace"
        continue
      fi
      break
    done
    say "  this user:
    identifier:  $id
      baked into the runner role name to be provisioned by Namazu
      Studios (their ONLY principal):
        $(runner_arn_of "$id" "$ws")
      and it is the sts:SourceIdentity their agent sessions must
      present — the id both sides attribute their actions to."
    new_entries+=("$id|$ws")
    read -r -p "  add another user? (y/N): " v || break
    [[ "$v" == "y" || "$v" == "Y" ]] || break
  done
  [[ ${#new_entries[@]} -gt 0 ]] || { echo "aborted"; return 0; }

  # Deploy ONE USER AT A TIME: each user is an independent Allow
  # statement, and IAM rejects trust principals that do not exist — a
  # bad identifier would otherwise roll back the whole batch (observed
  # live: one unknown principal sank every user in the update).
  # Deploying separately means the users before a failure stay applied,
  # and the culprit is named.
  local -a applied=()
  while IFS= read -r e; do applied+=("$e"); done < <(current_users)
  for e in ${new_entries[@]+"${new_entries[@]}"}; do
    applied+=("$e")
    local j
    j="$(printf '%s\n' ${applied[@]+"${applied[@]}"} | paste -sd, -)"
    if deploy_with_overrides "Users=$j" \
       && snapshot_stack \
       && [[ "$(snap_status)" == *_COMPLETE ]] \
       && [[ "$(snap_status)" != *ROLLBACK* ]]; then
      echo "  applied: $e"
    else
      say "FAILED on this user: $e
  Almost always the cause is the identifier: the runner role Namazu
  Studios provisioned for that workspace has a different one (IAM
  rejects unknown principals). Confirm the provisioned identifier
  with your Namazu contact, then re-add this user."
      snapshot_stack # post-rollback truth, not the pre-fail snapshot
      say "users actually on the stack right now:"
      list_users_entries
      events_hint
      return 1
    fi
  done
  say "done. users now on the stack:"
  local u
  for u in ${applied[@]+"${applied[@]}"}; do render_user "$u"; done
  say "each user's runner may now assume — presenting their identifier as
  the source identity plus the external ID. The report below is the
  exact configuration Namazu needs."
  print_ticket_report
}

# The remove operation: just removes. Pick a user, drop the entry,
# redeploy (the trust is recomposed without them).
remove_user() {
  updatable_stack || return 1
  local -a entries=()
  local e pick
  while IFS= read -r e; do
    [[ -n "$e" ]] && entries+=("$e")
  done < <(current_users)
  [[ ${#entries[@]} -gt 0 ]] || {
    say "no users in the list. The script now re-deploys to guarantee the
  trust matches the empty list (the deny-all) — it heals any drift."
    deploy_with_overrides "Users=" \
      && snapshot_stack \
      && say "done. the trust is the explicit deny (nobody authorized)." \
      || { echo "deploy failed"; events_hint; }
    return 0
  }
  say "users:"
  local i=1 u
  for u in ${entries[@]+"${entries[@]}"}; do
    echo "  $i) $(render_user "$u" | head -1)"
    local id ws
    IFS='|' read -r id ws <<< "$u"
    echo "      identifier/source identity: $id   workspace: $ws"
    i=$((i+1))
  done
  read -r -p "remove which (number): " pick || true
  [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le ${#entries[@]} ]] || die "invalid selection"
  local victim="${entries[$((pick-1))]}"
  local -a kept=()
  for e in ${entries[@]+"${entries[@]}"}; do [[ "$e" != "$victim" ]] && kept+=("$e"); done
  if [[ ${#kept[@]} -eq 0 ]]; then
    say "removing the last user — the trust returns to the explicit deny
  (nobody authorized). The role and its parameters stay."
    if ! confirm "remove them?"; then echo "aborted"; return 0; fi
  else
    say "users after this change:"
    for e in ${kept[@]+"${kept[@]}"}; do render_user "$e"; done
    confirm "apply to $STACK_NAME?" || { echo "aborted"; return 0; }
  fi
  local joined
  joined="$(printf '%s\n' ${kept[@]+"${kept[@]}"} | paste -sd, -)"
  if deploy_with_overrides "Users=$joined" \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]] \
     && [[ "$(snap_status)" != *ROLLBACK* ]]; then
    say "done. their runner can no longer assume — IAM takes effect
  immediately. Tell Namazu to drop the contract entry that names them."
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
      echo "use option 2 to add users to it."
      return 0
    fi
  fi

  # ONE SHOT: the stack + the empty role, nothing else asked. The
  # external ID is the one required decision — generated unless
  # --external-id supplied it — and everything else takes its
  # fail-safe template default (Sandbox catalog, no session pin, no
  # users). Users are wired AFTER create (option 2).
  local extid
  extid="${EXTERNAL_ID:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)}"
  [[ "$extid" =~ $EXTID_RE ]] || die "invalid --external-id (at least 2 characters; letters/digits/_+=,.@- only)"

  say "one-shot create:
  stack:      $STACK_NAME
  role:       exists immediately, trust = explicit deny (nobody authorized)
  external ID: $extid  (generated${EXTERNAL_ID:+, from --external-id})
  catalog:    Sandbox (the fail-safe default; flip with options 5/6)
  after create: add users (option 2) — each entry is one trust
                statement: their runner + their source identity."
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
  if [[ "$status" == *ROLLBACK* || "$status" == *FAILED* ]]; then
    say "⚠ the last update FAILED and rolled back — users added in that
  update are NOT on the stack (this is why they do not show below);
  the stack is stable and updatable, so re-adding them works."
  fi
  local catalog bencatalog outbound alliance extid sesspin
  catalog="$(snap_param CatalogPin)"
  bencatalog="$(snap_param BenefitsCatalogPin)"
  outbound="$(snap_param EnableOutboundEngagement)"
  alliance="$(snap_param EnableAllianceConnections)"
  extid="$(snap_param ExternalId)"
  sesspin="$(snap_param EnforceSessionName)"
  say "role:"
  echo "  ARN: $(ticket_role_arn)"
  say "users (the only thing that may assume; change: options 2/4):"
  list_users_entries
  say "IAM gates in force (change: options 5-8):"
  say "  selling catalog:   ${catalog:-<unmanaged>}"
  say "  funding catalog:   ${bencatalog:-<no funding grant in this stack template>}"
  say "  outbound engagement [partner-initiated co-sell]: ${outbound:-<not a knob in this stack template>}"
  say "  alliance connections [partner-to-partner]:       ${alliance:-<not a knob in this stack template>}"
  say "  external ID: ${extid:-none}   session-name pin: ${sesspin:-false}"
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
    say "the gates changed — tell Namazu: any report they hold shows the old gates."
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
  Onboarding order (each step has an owner): you create the
  namespaces for your users in Namazu Cloud -> Namazu Studios adds the
  co-selling agent to them (provisioning each workspace's runner role,
  cosell-agent-<identifier>-<workspace> — the runner must exist before
  its user can be added: IAM rejects unknown principals) -> you enable
  the principals in YOUR account with this script -> the ticket report
  goes to Namazu, who wires the deployment.

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
           users are NOT asked — the stack and the empty role exist
           the moment this finishes, with the trust an explicit deny
           for every principal.
   step 3  the script prints the ticket report: hand the external ID
           and the role ARN to your Namazu contact when ready.

2) ADD A USER (two questions, one at a time)
   step 1  the identifier — the label in the runner role name Namazu
           Studios provisions for that workspace:
           cosell-agent-<identifier>-<workspace> (the user's ONLY
           principal) and the sts:SourceIdentity their sessions
           present — the id both sides attribute that user's actions
           to. 2-20 characters, letters/digits/_+=,.@- only; you never
           paste an ARN. THE RULE: if the workspace already has a
           deployment, use the identifier already provisioned (your
           Namazu contact confirms it) — IAM rejects unknown
           principals, so a guess that does not match fails the update.
           For a new workspace, pick your org-internal notation (first
           initial + last name, e.g. jsmith) and share it with Namazu
           via the report; they provision it verbatim.
   step 2  the workspace id — exactly 24 hex characters: the id of
           their workspace in Namazu Cloud (e.g.
           0a1b2c3d4e5f6a7b8c9d0e1f). One user per workspace.
           After each user the script shows their entry + the runner
           ARN, and offers to add another; blank at the identifier
           stops.
   step 3  confirm. The stack is UPDATED — the script composes one
           Allow statement per user into the role's trust (their
           runner + their identifier as the source identity + the
           external ID); every other parameter is re-passed unchanged.
           Their runner can assume immediately.
   step 4  the script prints the ticket report — the exact
           configuration Namazu needs (the agent_apn entry per user).

3) LIST THE STATE
   The stack status, the role ARN, the user list (or the
   nobody-authorized state), the catalog pins, the motion toggles, and
   the external ID / session-pin state. Read-only.

4) REMOVE A USER
   step 1  pick the user by number.
   step 2  confirm. The script recomposes the trust without their
           statement; their runner cannot assume immediately.
           Removing the last user returns the role to the explicit
           deny — the role itself stays, ready for the next user.

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

0) DELETE THE ACCESS STACK
   Deletes the stack AND the role — there is no retain; all access
   stops immediately. Reversible only by recreating (option 1) with a
   fresh external ID and re-adding principals.

FIELD REFERENCE
  user entry    <identifier>|<workspace-id> — one user. identifier:
                the org-internal notation for the user (recommended:
                first initial + last name, e.g. jsmith), 2-20 chars
                (letters/digits/_+=,.@-); it is baked into the runner
                role name to be provisioned by Namazu Studios AND it
                is the sts:SourceIdentity their sessions present.
                workspace id: exactly 24 hex characters — their
                workspace in Namazu Cloud. Options 2/4 add and remove
                them; the trust gains/loses one Allow statement per
                user.
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
  session pin  forces each user's sessions to be named
               '<identifier>-session' (set session-pin=true). Enable
               only if the Namazu side configures session names.

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
  local users
  users="$(param_of "$fetched" Users)"
  echo "┌─ $stack — the agent deployment's gates [consume_role_arn] ──"
  echo "│  status: $status    drift: $(drift_dot "$drift")"
  if [[ "$status" == *ROLLBACK* || "$status" == *FAILED* ]]; then
    echo "│  ${C_R}⚠ the last update FAILED and rolled back — users added in it are${C_0}"
    echo "│  ${C_R}NOT applied; the stack is stable and updatable (re-add them).${C_0}"
  fi
  echo "│  selling  $(gate_dot selling "$selling")   funding  $(gate_dot funding "$funding")"
  echo "│  outbound $(gate_dot outbound "$outbound")   alliance $(gate_dot alliance "$alliance")"
  echo "│  external-id: ${extid:-none}    session-pin: ${sesspin:-false}"
  if [[ -n "$users" && "$users" != "None" ]]; then
    echo "│  users:"; echo "$users" | tr ',' '\n' | sed 's/^/│    /'
  else
    echo "│  ${C_Y}users: NONE${C_0} (the script recomposes the trust to the deny-all on every change)"
  fi
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
    echo "  \"users\": \"$(param_of "$fetched" Users)\""
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
    [[ -n "$pkey" ]] || die "unknown gate: $key [known: selling funding outbound alliance session-pin]"
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
  delete)     delete_stack; exit 0 ;;
  help)       show_help; exit 0 ;;
  menu)       : ;;
  *)          die "unknown command: $COMMAND (commands: status set drift delete menu help; or run with no command for the menu)" ;;
esac

interactive_menu() {
choice=""
while true; do
  echo
  echo "${C_B}Namazu co-selling agent — access manager${C_0}"
  render_dashboard
  echo
  echo "  1) Create the access stack (the role exists; nobody authorized yet)."
  echo "  2) Add a user (their runner principal + source identity)."
  echo "  3) List the role, users, and the IAM gates in force."
  echo "  4) Remove a user."
  echo "  5) Change the selling catalog (Sandbox / AWS / Both)."
  echo "  6) Change the funding catalog (Sandbox / AWS / Both)."
  echo "  7) Toggle outbound engagement (partner-initiated co-sell)."
  echo "  8) Toggle alliance connections (partner-to-partner)."
  echo "  0) Delete the access stack entirely."
  echo "  h) Help — what each option does, step by step."
  echo "  q) Quit."
  read -r -p "> " choice || { echo; exit 0; }
  case "$choice" in
    1) create_stack ;;
    2) add_user ;;
    3) list_state ;;
    4) remove_user ;;
    5) change_selling_catalog ;;
    6) change_funding_catalog ;;
    7) change_outbound_engagement ;;
    8) change_alliance_connections ;;
    0) delete_stack ;;
    h|H) show_help ;;
    q|Q) exit 0 ;;
    *) echo "Invalid choice — please enter 1–8, 0, h, or q." ;;
  esac
done
}
interactive_menu
