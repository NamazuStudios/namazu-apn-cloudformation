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
STACK_NAME="namazu-cosell-access"
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
                 (default: namazu-cosell-access)
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name) [[ $# -ge 2 ]] || die "--stack-name needs a value"; STACK_NAME="$2"; shift 2 ;;
    --region)     [[ $# -ge 2 ]] || die "--region needs a value"; AWS_DEFAULT_REGION="$2"; export AWS_DEFAULT_REGION; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

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
  catalog — placeholder data, safe to trial against) and 'AWS'
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
  say "IAM gates in force (change: options 6/7):"
  say "  selling catalog:   ${catalog:-<unmanaged>}"
  say "  funding catalog:   ${bencatalog:-<no funding grant in this stack template>}"
  say "  outbound engagement [partner-initiated co-sell]: ${outbound:-<not a knob in this stack template>}"
  say "  alliance connections [partner-to-partner]:       ${alliance:-<not a knob in this stack template>}"
  say "  external ID: ${extid:+set}${extid:-none}   session-name pin: ${sesspin:-false}"
  users="$(snap_users)"
  if [[ -z "$users" || "$users" == "None" ]]; then
    echo "no users in the stack"
    return 0
  fi
  say "current users and their role ARNs:"
  print_role_arns
}

# change_catalog — show the stack's current catalog and switch it. The
# catalog is enforced by IAM (the partnercentral:Catalog condition on
# every role), so this is the gate: Sandbox while trialing, AWS for
# production, Both for the move between them. Every other parameter is
# preserved.
change_catalog() {
  updatable_stack || return 1
  local cur
  cur="$(snap_param CatalogPin)"
  say "current catalog: ${cur:-<unset>}"
  say "  'Sandbox'  AWS's isolated test catalog — placeholder data, safe to trial against
  'AWS'      production — real opportunities and engagement invitations
  'Both'     grants both — only for moving to production co-sell work.
  There is no unpinned option: an operator always chooses. The agent-side
  catalog hint should be updated to match; the IAM condition decides."
  confirm "change the catalog?" || { echo "aborted"; return 0; }
  local v=""
  read -r -p "new catalog — Sandbox, AWS, or Both: " v || true
  case "$v" in
    Sandbox|AWS|Both) ;;
    *) die "catalog must be Sandbox, AWS, or Both" ;;
  esac
  [[ "$v" == "$cur" ]] && { say "already $v — nothing to do"; return 0; }
  say "users after this change: $(snap_users)"
  confirm "redeploy $STACK_NAME with catalog $v?" || { echo "aborted"; return 0; }
  if deploy_with_overrides "CatalogPin=$v" \
     && snapshot_stack \
     && [[ "$(snap_status)" == *_COMPLETE ]]; then
    say "done. catalog is now: $(snap_param CatalogPin)"
    say "remember to update the agent-side catalog hint to match (the IAM condition decides either way)."
  else
    echo "deploy failed"; events_hint; return 1
  fi
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

# Candidate names for options 1/2, harvested best-effort from classic IAM
# and IAM Identity Center (via each SSO instance's identity store). These
# are suggestions only — whatever is typed is still validated, and Identity
# Center UserNames are often email addresses that can exceed the
# 30-character role-name budget, in which case pick a shorter alias.
list_iam_candidates() {
  local out
  say "classic IAM users (first 100):"
  if out="$(aws iam list-users --max-items 100 --query 'Users[].UserName' --output text 2>/dev/null)"; then
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" | tr '\t' '\n' | while IFS= read -r u; do echo "  $u"; done
    else
      echo "  (none)"
    fi
  else
    echo "  (could not list — needs iam:ListUsers)"
  fi

  say "IAM Identity Center users:"
  if ! out="$(aws sso-admin list-instances --query 'Instances[].IdentityStoreId' --output text 2>/dev/null)"; then
    echo "  (could not list — needs sso-admin:ListInstances, in the region where Identity Center is enabled)"
    return 0
  fi
  if [[ -z "$out" ]]; then
    echo "  (no Identity Center instances in this account/region — Identity Center lives in the management or delegated-admin account's region)"
    return 0
  fi
  out="$(printf '%s\n' "$out" | tr '\t' '\n')" # one store id per line
  local store
  while IFS= read -r store; do
    [[ -n "$store" ]] || continue
    if out="$(aws identitystore list-users --identity-store-id "$store" --max-items 100 \
              --query 'Users[].[UserName,DisplayName]' --output text 2>/dev/null)"; then
      if [[ -n "$out" ]]; then
        printf '%s\n' "$out" | while IFS=$'\t' read -r un dn; do
          echo "  $un${dn:+  ($dn)}"
        done
      else
        echo "  (no users in identity store $store)"
      fi
    else
      echo "  (could not list identity store $store — needs identitystore:ListUsers)"
    fi
  done <<< "$out"

  say "these are suggestions only (capped at 100 per source) — a chosen name must be 2-30 characters (letters/digits/_+=,.@-); it becomes part of the role name and the sts:SourceIdentity."
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

3) LIST CURRENT USERS
   Shows the stack status, the catalog in force (enforced by IAM),
   whether an external ID / session pin is set, every user, and their
   role ARN. Read-only.

4) LIST CANDIDATE USERS
   A best-effort, read-only sweep of classic IAM users and IAM
   Identity Center users (one query per SSO instance), to copy
   sensible names from. Identity Center names are often email
   addresses — usually too long for the 30-character role-name
   budget; pick a shorter alias for those people. Needs
   iam:ListUsers / sso-admin:ListInstances / identitystore:ListUsers,
   and the Identity Center lookup only works in the region where
   Identity Center is enabled.

5) REMOVE A USER
   step 1  pick the user by number from the current list.
   step 2  confirm. The stack is updated with the shortened Users
           list and that user's IAM role is deleted with it. The
           person loses access immediately.
   note    when one user remains, removing them would leave an empty
           Users list — the template forbids that, so the script
           offers to delete the whole stack instead.

6) CHANGE THE CATALOG
   Shows the catalog currently in force and switches it between
   'Sandbox' (AWS's isolated test catalog — placeholder data),
   'AWS' (production — real opportunities), and 'Both'. The choice is
   enforced by IAM: every role in the stack carries a
   partnercentral:Catalog condition. Every other parameter (users,
   external ID, session pin) is preserved. There is no unpinned
   option: an operator always chooses. Update the agent-side catalog
   hint to match — the IAM condition decides either way.

7) DELETE THE ACCESS STACK
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
  catalog       'Sandbox', 'AWS', or 'Both' (see option 6); default
                Sandbox. Enforced by IAM — the agent-side catalog hint
                should match.
  session pin   forces sessions to be named '<user>-session'; enable
                only if the Namazu side configures session names.

CLI FLAGS
  --stack-name  manage a different stack (default namazu-cosell-access)
  --region      region for the AWS calls (default: your CLI config)
EOF
}

# ---- menu -------------------------------------------------------------------
choice=""
while true; do
  echo
  echo "Namazu co-selling agent — access manager"
  status="$(stack_status)"
  echo "  stack: $STACK_NAME (${status:-not created yet})"
  echo
  echo "  1) Create the access stack (first-time setup)."
  echo "  2) Add a user."
  echo "  3) List current users, their role ARNs, and the catalog."
  echo "  4) List candidate users (IAM / IAM Identity Center)."
  echo "  5) Remove a user."
  echo "  6) Change the catalog (Sandbox / AWS / Both)."
  echo "  7) Delete the access stack entirely."
  echo "  h) Help — what each option does, step by step."
  echo "  q) Quit."
  read -r -p "> " choice || { echo; exit 0; }
  case "$choice" in
    1) create_stack ;;
    2) add_users ;;
    3) list_users ;;
    4) list_iam_candidates ;;
    5) remove_user ;;
    6) change_catalog ;;
    7) delete_stack ;;
    h|H) show_help ;;
    q|Q) exit 0 ;;
    *) echo "Invalid choice — please enter 1–7, h, or q." ;;
  esac
done
