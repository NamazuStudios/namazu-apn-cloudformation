#!/usr/bin/env bash
# manage-access.sh — interactive manager for the Namazu co-selling agent's
# customer-side access: creates the CloudFormation stack from
# templates/per-user-roles.yaml (option 1, first-time setup), adds/removes
# users, and lists them (with role ARNs) alongside candidate user names
# harvested from classic IAM and IAM Identity Center. One stack holds every
# user; the stack's `Users` parameter IS the user list, so add/remove is a
# stack update and list is reading it back.
#
# The shared-role template (templates/opportunity-manager-role.yaml) is NOT
# managed here: it is a single-user, one-off deploy for the
# single-account-manager case — see README.md for its direct
# `aws cloudformation deploy` flow.
#
# Requirements: bash + the AWS CLI, authenticated as a principal allowed to
# create IAM roles in the AWS account linked to your Partner Central
# account. No other dependencies (no jq — parsing is done with --query).
#
# Usage: ./manage-access.sh [--stack-name NAME] [--region REGION]
#
# Copyright 2026 Namazu Studios LLC. Licensed AGPL-3.0 — see LICENSE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/templates/per-user-roles.yaml"
STACK_NAME="namazu-cosell-manager"
NEW_USERS=() # filled by read_users_input, consumed by create_stack/add_users

# IAM role-name rules as the template enforces them (also validated
# server-side by AllowedPattern — this is the friendly, fail-fast copy):
# 2-30 characters, letters/digits/_+=,.@- only. 30 because the template's
# role-name prefix takes 34 of IAM's 64.
USER_RE='^[A-Za-z0-9_+=,.@-]{2,30}$'
EXTID_RE='^[A-Za-z0-9_+=,.@-]{2,1224}$'

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

Menu: create the stack, add/remove users, list current users with their
role ARNs, list candidate user names from IAM / IAM Identity Center, or
delete the stack. In the menu, 'h' shows a detailed help: what each
option does, step by step, plus a field reference.

Requires: bash, the AWS CLI, and credentials for the AWS account linked to
your Partner Central account. Manages templates/per-user-roles.yaml — for
the single-user shared-role template, see README.md.
EOF
}

# ---- flags ------------------------------------------------------------------
YES=0; JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name) [[ $# -ge 2 ]] || die "--stack-name needs a value"; STACK_NAME="$2"; shift 2 ;;
    --region)     [[ $# -ge 2 ]] || die "--region needs a value"; AWS_DEFAULT_REGION="$2"; export AWS_DEFAULT_REGION; shift 2 ;;
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
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Parameters[?ParameterKey=='Users'].ParameterValue | [0]" \
    --output text 2>/dev/null >"$SNAP_DIR/users" &
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
snap_users()  { cat "$SNAP_DIR/users"  2>/dev/null; }

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

deploy_with_users() { # $1 = the new comma-separated Users value
  deploy_with_overrides "Users=$1"
}

events_hint() {
  echo "  for the reason: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region <your-region>"
}

# RoleArn outputs from the current snapshot, tab-separated (one line per user).
print_role_arns() { # $@ = users to report (empty = all)
  [[ -n "$SNAP_DIR" ]] || snapshot_stack
  local want="${*:-}"
  local key arn user
  while IFS=$'\t' read -r key arn; do
    [[ -n "$key" ]] || continue
    user="${key#RoleArn}"
    if [[ -z "$want" || " $want " == *" $user "* ]]; then
      echo "  $user -> $arn"
    fi
  done < "$SNAP_DIR/arns"
}

confirm() { # $1 = question; returns 0 on yes
  local reply=""
  read -r -p "$1 [y/N]: " reply || true
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" ]]
}

valid_user() { [[ "$1" =~ $USER_RE ]] ; }

# Case-folded form of a name — IAM role names are not case-sensitive for
# uniqueness, so duplicate detection compares folded.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

# Reads a comma- or space-separated batch of names into NEW_USERS: validated
# against USER_RE and de-duplicated within the batch (case-insensitively —
# two names differing only by case would collide in IAM role names anyway).
read_users_input() {
  local input="" u l batch_lower="" raw=()
  NEW_USERS=()
  say "what a user name is:
  each name becomes its own IAM role, named
      Namazu-CoSell-Opportunity-Manager-<name>
  and becomes the sts:SourceIdentity every CloudTrail entry shows for
  that person's agent sessions — so pick an identifier that matches
  the human (their personal username, not a group or shared account).
  rules: 2-30 characters; letters, digits, and _+=,.@- only; spaces
  you type are treated as commas. (menu option 4 lists candidates)"
  read -r -p "user name(s) to add (comma-separated): " input || true
  input="${input// /,}"
  IFS=',' read -ra raw <<< "$input"
  for u in ${raw[@]+"${raw[@]}"}; do
    [[ -n "$u" ]] || continue
    valid_user "$u" || die "invalid user name '$u': 2-30 characters, letters/digits/_+=,.@- only (it becomes part of an IAM role name)"
    l="$(lower "$u")"
    case ",${batch_lower}," in
      *",$l,"*) echo "  skipping '$u' — duplicate in this batch"; continue ;;
    esac
    batch_lower="${batch_lower:+$batch_lower,}$l"
    NEW_USERS+=("$u")
  done
  [[ ${#NEW_USERS[@]} -gt 0 ]] || die "no user names given"
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
  local extra=() overrides=() v u status=""
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
      echo "use option 2 to add a user to it."
      return 0
    fi
  fi

  read_users_input
  local users_value
  users_value="$(IFS=','; echo "${NEW_USERS[*]}")"

  # First create: offer the optional hardening/pinning parameters with
  # sensible defaults (later updates preserve whatever is chosen here).
  say "external ID (optional):
  an extra secret the Namazu agent must present when assuming these
  roles — confused-deputy protection on top of the account trust.
  Set one only if your Namazu contact asked for it: they must
  configure the same value on the agent side, or every assume-role
  is denied. rules: 2+ characters; letters, digits, and _+=,.@- only."
  v=""
  read -r -p "external ID for extra protection (blank: none): " v || true
  if [[ -n "$v" ]]; then
    [[ "$v" =~ $EXTID_RE ]] || die "invalid external ID (at least 2 characters; letters/digits/_+=,.@- only)"
    extra+=("ExternalId=$v")
  fi
  say "catalog:
  Partner Central has two catalogs: 'Sandbox' (AWS's isolated test
  catalog — placeholder data, safe to exercise against) and 'AWS'
  (production — real opportunities and engagement invitations). The
  choice is enforced by IAM: every role in this stack gets a condition
  limiting it to the chosen catalog. 'Both' grants both catalogs —
  only for moving to production co-sell work. There is no unpinned
  option: an operator always chooses. default: Sandbox."
  v=""
  read -r -p "catalog — Sandbox, AWS, or Both (Sandbox): " v || true
  v="${v:-Sandbox}"
  case "$v" in
    Sandbox|AWS|Both) ;;
    *) die "catalog must be Sandbox, AWS, or Both" ;;
  esac
  extra+=("CatalogPin=$v")
  say "Namazu agent principals (optional):
  the IAM roles in Namazu's hosting account that the agent's pods
  assume from — one per agent workspace, named
      arn:aws:iam::308044622771:role/cosell-runner-<workspace-id>
  Your Namazu contact provides the exact ARNs. Setting them pins the
  trust to exactly those roles (recommended — no account-root trust);
  the per-person SourceIdentity conditions still apply to every
  principal. Blank keeps the account-root trust."
  v=""
  read -r -p "agent role ARNs, comma-separated (blank: account-root trust): " v || true
  if [[ -n "$v" ]]; then
    local r
    local -a arn_parts=()
    IFS=',' read -ra arn_parts <<< "$v"
    for r in ${arn_parts[@]+"${arn_parts[@]}"}; do
      [[ "$r" =~ ^arn:aws:iam::[0-9]{12}:role/ ]] || die "not a role ARN: $r"
    done
    extra+=("AgentRoleArns=$v")
  fi
  say "session-name pin (optional):
  when enabled, each role only accepts sessions named '<user>-session'
  (e.g. peter-session) — one more thing enforced and visible in
  CloudTrail, but the agent deployment must use exactly that name.
  Enable only if your Namazu contact confirms their deployments set it."
  v=""
  read -r -p "enforce per-user session names? (blank: no): " v || true
  [[ "$v" == "y" || "$v" == "yes" ]] && extra+=("EnforceSessionName=true")

  say "users after this change: $users_value"
  confirm "create stack $STACK_NAME?" || { echo "aborted"; return 0; }

  overrides=("Users=$users_value")
  for u in ${extra[@]+"${extra[@]}"}; do overrides+=("$u"); done
  aws cloudformation deploy \
    --template-file "$TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "${overrides[@]}" \
    || { echo "deploy failed"; events_hint; return 1; }

  snapshot_stack # the create added outputs
  say "done. stack status: $(snap_status). Role ARNs to hand to your Namazu contact:"
  print_role_arns ${NEW_USERS[@]+"${NEW_USERS[@]}"}
}

add_users() {
  updatable_stack || return 1
  local current users_value seen_dup=0
  local existing=() u u2 ex_lower="" l
  current="$(snap_users)"
  [[ -n "$current" && "$current" != "None" ]] || current=""

  read_users_input

  # Duplicates against the stack (case-insensitively — IAM role names are
  # not case-sensitive for uniqueness).
  IFS=',' read -ra existing <<< "$current"
  for u2 in ${existing[@]+"${existing[@]}"}; do
    [[ -n "$u2" ]] || continue
    ex_lower="${ex_lower:+$ex_lower,}$(lower "$u2")"
  done
  for u in ${NEW_USERS[@]+"${NEW_USERS[@]}"}; do
    l="$(lower "$u")"
    case ",$ex_lower," in
      *",$l,"*) echo "user '$u' already exists"; seen_dup=1 ;;
    esac
  done
  [[ $seen_dup -eq 1 ]] && return 1

  if [[ -n "$current" ]]; then
    users_value="$current,$(IFS=','; echo "${NEW_USERS[*]}")"
  else
    users_value="$(IFS=','; echo "${NEW_USERS[*]}")"
  fi
  say "users after this change: $users_value"

  confirm "apply this change to stack $STACK_NAME?" || { echo "aborted"; return 0; }

  # Plain update: preserve every existing parameter (from the snapshot),
  # swap Users.
  deploy_with_users "$users_value" || { echo "deploy failed"; events_hint; return 1; }

  snapshot_stack # the update added outputs
  say "done. Role ARNs to hand to your Namazu contact:"
  print_role_arns ${NEW_USERS[@]+"${NEW_USERS[@]}"}
}

list_users() {
  snapshot_stack
  local status users
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
  say "IAM gates in force (change: options 5-8):"
  say "  selling catalog:   ${catalog:-<unmanaged>}"
  say "  funding catalog:   ${bencatalog:-<no funding grant in this stack template>}"
  say "  outbound engagement [partner-initiated co-sell]: ${outbound:-<not a knob in this stack template>}"
  say "  alliance connections [partner-to-partner]:       ${alliance:-<not a knob in this stack template>}"
  say "  external ID: ${extid:+set}${extid:-none}   session-name pin: ${sesspin:-false}"
  if [[ -z "$(snap_param AgentRoleArns)" ]]; then
    say "NOTE: this is a per-user stack — its gates bind the individual roles
  listed below (each person's own agent deployment), NOT the shared role
  a given agent deployment assumes. Check which role your deployment's
  consume_role_arn points at, and manage THAT stack with --stack-name."
  fi
  users="$(snap_users)"
  if [[ -z "$users" || "$users" == "None" ]]; then
    echo "no users in the stack"
    return 0
  fi
  say "current users and their role ARNs:"
  print_role_arns
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
  say "users after this change: $(snap_users)"
  confirm "redeploy $STACK_NAME with $key=$v?" || { echo "aborted"; return 0; }
  if deploy_with_overrides "$key=$v" \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]]; then
    local newval
    newval="$(snap_param "$key")"
    say "done. $label is now: $newval"
    say "IAM re-evaluates per request; a live agent session picks this up at its next credential refresh, about 1h. Update the agent-side hint to match. IAM decides either way."
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

remove_user() {
  updatable_stack || return 1
  local users
  users="$(snap_users)"
  [[ -n "$users" && "$users" != "None" ]] || { echo "no users in the stack"; return 0; }
  local existing=()
  IFS=',' read -ra existing <<< "$users"
  if [[ ${#existing[@]} -eq 1 ]]; then
    say "only one user left (${existing[0]}) — removing them leaves an empty stack."
    if confirm "delete the whole stack instead?"; then
      if aws cloudformation delete-stack --stack-name "$STACK_NAME" \
         && aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
        say "stack deleted (the IAM role went with it)"
      else
        echo "delete failed"; events_hint; return 1
      fi
    else
      echo "aborted"
    fi
    return 0
  fi
  say "current users:"
  local i=1 u n=""
  for u in ${existing[@]+"${existing[@]}"}; do echo "  $i) $u"; i=$((i+1)); done
  read -r -p "remove which (number): " n || true
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le ${#existing[@]} ]] || die "invalid selection"
  local victim="${existing[$((n-1))]}"
  local kept=()
  for u in ${existing[@]+"${existing[@]}"}; do [[ "$u" != "$victim" ]] && kept+=("$u"); done
  say "removing '$victim'; users after this change: $(IFS=','; echo "${kept[*]}")"
  confirm "apply?" || { echo "aborted"; return 0; }
  deploy_with_users "$(IFS=','; echo "${kept[*]}")" \
    || { echo "deploy failed"; events_hint; return 1; }
  snapshot_stack # the update removed outputs
  say "done. '$victim' and their role are gone; remaining users:"
  print_role_arns
}

delete_stack() {
  stack_exists || { echo "no stack $STACK_NAME — nothing to delete"; return 0; }
  confirm "delete stack $STACK_NAME and every user role in it?" || { echo "aborted"; return 0; }
  if aws cloudformation delete-stack --stack-name "$STACK_NAME" \
     && aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
    say "stack deleted (all per-user IAM roles went with it)"
  else
    echo "delete failed"; events_hint; return 1
  fi
}

# Detailed, task-by-task help (menu option h).
show_help() {
  cat <<'EOF'

how this tool works, task by task
=================================

THE MODEL
  One CloudFormation stack holds every user. Its `Users` parameter IS
  the list of people with access; each name gets its own IAM role
  (Namazu-CoSell-Opportunity-Manager-<name>) that only the Namazu
  hosting account may assume, and only when the session carries that
  person's name as the sts:SourceIdentity. Roles are separate, so
  access is per-person visible in CloudTrail and revocable
  independently.

1) CREATE THE ACCESS STACK (first-time setup)
   step 1  make sure you are authenticated to the AWS account linked
           to your Partner Central account (shown in the header).
   step 2  enter one or more user names (see FIELD REFERENCE below).
   step 3  optionally set an external ID, a catalog pin, and/or the
           session-name pin (see FIELD REFERENCE). These are only
           asked here; later edits preserve them.
   step 4  confirm — the script deploys the stack and prints each
           user's role ARN.
   step 5  hand the role ARNs (and the external ID, if you set one)
           to your Namazu contact; they wire them into the agent
           deployment on their side.

2) ADD A USER
   step 1  enter the name(s). Duplicates — already on the stack or
           repeated in your input, even differing only in case — are
           rejected.
   step 2  confirm. The stack is UPDATED with the extended Users
           list; every other parameter is re-passed unchanged, so an
           external ID / catalog pin chosen at creation survives.
   step 3  hand the new role ARN to your Namazu contact.

3) LIST USERS AND THE IAM GATES IN FORCE
   Shows the stack status, both catalog pins (selling and funding),
   the motion toggles (outbound engagement, alliance connections),
   the external ID / session-pin state, every user, and their role
   ARN. Read-only. Anything the stack's template doesn't manage is
   labeled as such.

4) REMOVE A USER
   step 1  pick the user by number from the current list.
   step 2  confirm. The stack is updated with the shortened Users
           list and that user's IAM role is deleted with it. The
           person loses access immediately.
   note    when one user remains, removing them would leave an empty
           Users list — the template forbids that, so the script
           offers to delete the whole stack instead.

5) CHANGE THE SELLING CATALOG
   partnercentral-selling — opportunities, invitations, solutions.
   Enforced by IAM on every role in the stack ('Sandbox' for sandbox
   'AWS' production / 'Both'; there is no unpinned option: an
   operator always chooses). Every other parameter is preserved;
   update the agent-side catalog hint to match (the IAM condition
   decides either way).

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
   Deletes the stack and EVERY user role in it; all Namazu agent
   access stops immediately. Reversible only by recreating (option 1)
   and re-sharing the fresh role ARNs.

FIELD REFERENCE
  user name     2-30 characters, letters/digits/_+=,.@-; becomes part
                of the IAM role name, the role's AuthorizedUser tag,
                and the sts:SourceIdentity the agent must present.
  external ID   optional shared secret for assume-role (2+ chars,
                same charset). Only set it with your Namazu contact's
                agreement — misconfigured means every assume is denied.
  catalogs      'Sandbox', 'AWS', or 'Both' for each of selling and
                funding (see options 5 and 6); enforced by IAM.
  motions       'true'/'false' toggles for outbound engagement
                (option 7) and alliance connections (option 8).
  session pin   forces sessions to be named '<user>-session'; set
                at create time. Enable only if the Namazu side
                configures session names.

CLI FLAGS
  --stack-name  manage a different stack (default namazu-cosell-manager)
  --region      region for the AWS calls (default: your CLI config)
EOF
}

# ---- gate registry -----------------------------------------------------------
gate_param() {
  case "$1" in
    selling)        echo "CatalogPin" ;;
    funding)        echo "BenefitsCatalogPin" ;;
    outbound)       echo "EnableOutboundEngagement" ;;
    alliance)       echo "EnableAllianceConnections" ;;
    *) echo "" ;;
  esac
}

gate_label() {
  case "$1" in
    selling)        echo "selling catalog" ;;
    funding)        echo "funding catalog" ;;
    outbound)       echo "outbound engagement [partner-initiated co-sell]" ;;
    alliance)       echo "alliance connections [partner-to-partner]" ;;
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
  local status drift selling funding outbound alliance extid sesspin users agents auser title warn
  status="$(field_of "$fetched" "S:")"
  drift="$(field_of "$fetched" "D:")"
  selling="$(param_of "$fetched" CatalogPin)"
  funding="$(param_of "$fetched" BenefitsCatalogPin)"
  outbound="$(param_of "$fetched" EnableOutboundEngagement)"
  alliance="$(param_of "$fetched" EnableAllianceConnections)"
  extid="$(param_of "$fetched" ExternalId)"
  sesspin="$(param_of "$fetched" EnforceSessionName)"
  users="$(param_of "$fetched" Users)"
  agents="$(param_of "$fetched" AgentRoleArns)"
  auser="$(param_of "$fetched" AuthorizedUser)"
  if [[ -n "$users" && "$users" != "None" ]]; then
    title="per-user stack"
    warn="${C_Y}⚠${C_0} gates bind the roles below — not the agent's deployment"
  else
    title="shared-role stack"
    warn="the agent deployment's gates [consume_role_arn]"
  fi
  echo "┌─ $stack — $title ───────────────────────────────────"
  echo "│  $warn"
  echo "│  status: $status    drift: $(drift_dot "$drift")"
  echo "│  selling  $(gate_dot selling "$selling")   funding  $(gate_dot funding "$funding")"
  echo "│  outbound $(gate_dot outbound "$outbound")   alliance $(gate_dot alliance "$alliance")"
  echo "│  external-id: ${extid:+set}${extid:-none}    session-pin: ${sesspin:-false}"
  [[ -n "$agents" ]] && { echo "│  principals:"; echo "$agents" | tr ',' '\n' | sed 's/^/│    /'; }
  [[ -n "$auser" ]] && echo "│  AuthorizedUser: $auser"
  [[ -n "$users" && "$users" != "None" ]] && echo "│  users: $(echo "$users" | tr ',' ' ')"
  echo "└───────────────────────────────────────────────────────"
}

render_dashboard() {
  # Cards render only for stacks that EXIST — a deleted or not-created
  # stack (e.g. the per-user customer stack in an account where it isn't
  # used) gets a one-line hint, never a card box that reads like a live
  # gate panel.
  local -a stacks=("$STACK_NAME")
  local other="namazu-cosell-manager"
  [[ "$STACK_NAME" == "namazu-cosell-manager" ]] && other="namazu-cosell-access"
  stacks+=("$other")
  local s ta="/tmp/opencode/mas-state-a.$$.tmp" tb="/tmp/opencode/mas-state-b.$$.tmp"
  fetch_stack_state "${stacks[0]}" > "$ta" 2>&1 &
  fetch_stack_state "${stacks[1]}" > "$tb" 2>&1 &
  wait
  local i=0
  for s in ${stacks[@]+"${stacks[@]}"}; do
    local f; f="$ta"; [[ $i -eq 1 ]] && f="$tb"
    if head -1 "$f" 2>/dev/null | grep -q "^MISSING$"; then
      echo "${C_D}· $s: not created${C_0}"
    else
      render_card_from "$f" "$s"
    fi
    i=$((i + 1))
  done
  rm -f "$ta" "$tb"
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
  local -a stacks=("$STACK_NAME")
  local other="namazu-cosell-manager"
  [[ "$STACK_NAME" == "namazu-cosell-manager" ]] && other="namazu-cosell-access"
  stacks+=("$other")
  local s id res
  for s in ${stacks[@]+"${stacks[@]}"}; do
    id="$(aws cloudformation detect-stack-drift --stack-name "$s" --query 'StackDriftDetectionId' --output text 2>/dev/null)"
    if [[ -z "$id" || "$id" == "None" ]]; then echo "$s: detection failed"; continue; fi
    printf '%s: detecting…' "$s"
    for i in $(seq 1 20); do
      sleep 5
      res="$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$id" --query 'StackDriftDetectionStatus' --output text 2>/dev/null)"
      case "$res" in DETECTION_COMPLETE|DETECTION_FAILED) break;; esac
    done
    printf '\r%s: ' "$s"
    aws cloudformation describe-stack-resource-drifts --stack-name "$s" \
      --query 'StackResourceDrifts[0].StackResourceDriftStatus' --output text 2>/dev/null || echo "n/a"
  done
  echo "(the dashboard shows drift from the last detection)"
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
    [[ -n "$pkey" ]] || die "unknown gate: $key [known: selling funding outbound alliance]"
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
  say "users after this change: $(snap_users)"
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
  echo "  1) Create the access stack (first-time setup)."
  echo "  2) Add a user."
  echo "  3) List users, role ARNs, and the IAM gates in force."
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
    2) add_users ;;
    3) list_users ;;
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
