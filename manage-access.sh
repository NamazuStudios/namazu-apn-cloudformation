#!/usr/bin/env bash
# manage-access.sh — interactive manager for the Namazu co-selling agent's
# customer-side access: creates/updates the CloudFormation stack from
# templates/per-user-roles.yaml, lists the users (and their role ARNs), and
# removes users again. One stack holds every user; the stack's `Users`
# parameter IS the user list, so add/remove is a stack update and list is
# reading it back.
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
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/templates/per-user-roles.yaml"
STACK_NAME="namazu-cosell-access"

# IAM role-name rules as the template enforces them (also validated
# server-side by AllowedPattern — this is the friendly, fail-fast copy):
# 2-30 characters, letters/digits/_+=,.@- only. 30 because the template's
# role-name prefix takes 34 of IAM's 64.
USER_RE='^[A-Za-z0-9_+=,.@-]{2,30}$'
EXTID_RE='^[A-Za-z0-9_+=,.@-]{2,1224}$'

die() { echo "error: $*" >&2; exit 1; }
say() { echo; echo "$*"; }

usage() {
  cat <<'EOF'
manage-access.sh — manage Namazu co-selling agent access (interactive)

Usage: ./manage-access.sh [--stack-name NAME] [--region REGION]

  --stack-name   the CloudFormation stack to manage
                 (default: namazu-cosell-access)
  --region       AWS region for the CloudFormation calls
                 (default: your AWS CLI's configured region)

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
stack_status() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null
}
stack_exists() { [[ -n "$(stack_status)" ]] ; }

get_users() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Parameters[?ParameterKey=='Users'].ParameterValue | [0]" \
    --output text 2>/dev/null
}

# Every parameter currently on the stack, tab-separated Key<TAB>Value —
# the basis for the never-drop-a-parameter rule below.
all_params_raw() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' \
    --output text 2>/dev/null
}

# `aws cloudformation deploy` resets any parameter it is NOT given back to
# the template's default — so before any update we read the stack's current
# parameters and re-pass every one of them, substituting only Users. Without
# this, adding a second user would silently wipe a CatalogPin or ExternalId
# set at creation time.
deploy_with_users() { # $1 = the new comma-separated Users value
  local new_users="$1" k v
  local overrides=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    [[ "$k" == "Users" ]] && v="$new_users"
    overrides+=("$k=$v")
  done < <(all_params_raw)
  aws cloudformation deploy \
    --template-file "$TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ${overrides[@]+"${overrides[@]}"}
}

events_hint() {
  echo "  for the reason: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region <your-region>"
}

# RoleArn outputs, tab-separated Key<TAB>Value (one line per user).
# (The JMESPath literal backticks below are intentional — no shell expansion.)
# shellcheck disable=SC2016
role_outputs() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[?starts_with(OutputKey, `RoleArn`)].[OutputKey,OutputValue]' \
    --output text 2>/dev/null
}

print_role_arns() { # $@ = users to report (empty = all)
  local want="${*:-}"
  local key arn user
  while IFS=$'\t' read -r key arn; do
    [[ -n "$key" ]] || continue
    user="${key#RoleArn}"
    if [[ -z "$want" || " $want " == *" $user "* ]]; then
      echo "  $user -> $arn"
    fi
  done < <(role_outputs)
}

confirm() { # $1 = question; returns 0 on yes
  local reply=""
  read -r -p "$1 [y/N]: " reply || true
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" ]]
}

valid_user() { [[ "$1" =~ $USER_RE ]] ; }

# ---- preflight --------------------------------------------------------------
echo "Namazu co-selling agent — access manager"
echo "stack: $STACK_NAME"
account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "could not authenticate to AWS (aws sts get-caller-identity failed). Configure credentials for the account linked to your Partner Central account, then retry."
region="$(aws configure get region 2>/dev/null || echo '(default)')"
echo "aws account: $account   region: $region"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE (run this from the repo checkout)"
say "-------------------------------------------"

# ---- actions ----------------------------------------------------------------
add_users() {
  local input="" u v new=() raw=() seen_dup=0 current="" status
  read -r -p "user name(s) to add (comma-separated): " input || true
  input="${input// /,}"
  IFS=',' read -ra raw <<< "$input"
  for u in ${raw[@]+"${raw[@]}"}; do
    [[ -n "$u" ]] || continue
    valid_user "$u" || die "invalid user name '$u': 2-30 characters, letters/digits/_+=,.@- only (it becomes part of an IAM role name)"
    new+=("$u")
  done
  [[ ${#new[@]} -gt 0 ]] || die "no user names given"

  if stack_exists; then
    status="$(stack_status)"
    if [[ "$status" == "ROLLBACK_COMPLETE" ]]; then
      say "stack $STACK_NAME is in ROLLBACK_COMPLETE (a failed create) — it can only be deleted, not updated."
      confirm "delete it and recreate fresh with these users?" || die "aborted (delete it manually, then rerun)"
      if aws cloudformation delete-stack --stack-name "$STACK_NAME" \
         && aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
        :
      else
        echo "delete failed"; events_hint; return 1
      fi
    else
      current="$(get_users)"
      local existing=() u2
      IFS=',' read -ra existing <<< "$current"
      for u in ${new[@]+"${new[@]}"}; do
        for u2 in ${existing[@]+"${existing[@]}"}; do
          [[ "$u" == "$u2" ]] && { echo "user '$u' already exists"; seen_dup=1; }
        done
      done
      [[ $seen_dup -eq 1 ]] && return 1
    fi
  fi

  local users_value
  if [[ -n "$current" ]]; then
    users_value="$current,$(IFS=','; echo "${new[*]}")"
  else
    users_value="$(IFS=','; echo "${new[*]}")"
  fi
  say "users after this change: $users_value"

  local extra=()
  if ! stack_exists; then
    # First create: offer the optional hardening/pinning parameters with
    # sensible defaults (later updates preserve whatever is chosen here).
    v=""
    read -r -p "external ID for extra protection (blank: none): " v || true
    if [[ -n "$v" ]]; then
      [[ "$v" =~ $EXTID_RE ]] || die "invalid external ID (at least 2 characters; letters/digits/_+=,.@- only)"
      extra+=("ExternalId=$v")
    fi
    v=""
    read -r -p "catalog pin — AWS, Sandbox, or blank for none (blank): " v || true
    if [[ -n "$v" ]]; then
      [[ "$v" == "AWS" || "$v" == "Sandbox" ]] || die "catalog pin must be AWS or Sandbox"
      extra+=("CatalogPin=$v")
    fi
    v=""
    read -r -p "enforce per-user session names? (blank: no): " v || true
    [[ "$v" == "y" || "$v" == "yes" ]] && extra+=("EnforceSessionName=true")
  fi

  confirm "apply this change to stack $STACK_NAME?" || { echo "aborted"; return 0; }

  if [[ -n "$current" && ${#extra[@]} -eq 0 ]]; then
    # Plain update: preserve every existing parameter, swap Users.
    deploy_with_users "$users_value" || { echo "deploy failed"; events_hint; return 1; }
  else
    # Create (or recreate after a rollback): Users plus what was gathered.
    local overrides=("Users=$users_value")
    for u in ${extra[@]+"${extra[@]}"}; do overrides+=("$u"); done
    aws cloudformation deploy \
      --template-file "$TEMPLATE" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides "${overrides[@]}" \
      || { echo "deploy failed"; events_hint; return 1; }
  fi

  say "done. Role ARNs to hand to your Namazu contact:"
  print_role_arns ${new[@]+"${new[@]}"}
}

list_users() {
  stack_exists || { echo "no stack $STACK_NAME yet — nothing to list (use option 1)"; return 0; }
  echo "stack: $STACK_NAME ($(stack_status))"
  local users
  users="$(get_users)"
  if [[ -z "$users" || "$users" == "None" ]]; then
    echo "no users in the stack"
    return 0
  fi
  say "current users and their role ARNs:"
  print_role_arns
}

remove_user() {
  stack_exists || { echo "no stack $STACK_NAME yet — nothing to remove"; return 0; }
  local users
  users="$(get_users)"
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

# ---- menu -------------------------------------------------------------------
choice=""
while true; do
  echo
  echo "  1) add a user"
  echo "  2) list current users"
  echo "  3) remove a user"
  echo "  4) delete the access stack entirely"
  echo "  q) quit"
  read -r -p "> " choice || { echo; exit 0; }
  case "$choice" in
    1) add_users ;;
    2) list_users ;;
    3) remove_user ;;
    4) delete_stack ;;
    q|Q) exit 0 ;;
    *) echo "huh? (1-4 or q)" ;;
  esac
done
