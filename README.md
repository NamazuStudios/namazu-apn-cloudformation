# namazu-apn-cloudformation

CloudFormation templates for granting the **Namazu co-selling agent**
access to your AWS account's Partner Central co-selling opportunities.

The Namazu co-selling agent is an AI assistant that works co-sell deals
in [AWS Partner Central](https://aws.amazon.com/partners/) on your
behalf: updating opportunities, responding to AWS referrals, submitting
deals for AWS co-sell review, keeping deal summaries current, and turning
them into client-ready documents. To do that it needs an IAM role in the
AWS account that is linked to your Partner Central — which is what these
templates create.

## How access works (and why it's safe)

The agent never holds static AWS credentials of any kind. Every request
it makes is performed under an **assumed role in your account**, taken
via AWS STS from Namazu's own hosting account, and — this is the part
that matters — every session it opens carries an individual **source
identity**. Each role created by these templates:

- trusts **only** Namazu's hosting account (principally-scoped trust —
  no wildcards),
- accepts assumptions **only** when the presented
  `sts:SourceIdentity` exactly matches the role's `AuthorizedUser` tag —
  so every action the agent takes appears in your CloudTrail under a
  named person, and you can revoke one person's access by deleting or
  re-tagging their role at any time,
- grants **only** Partner Central opportunity-management actions
  (`partnercentral:*` on the opportunity/referral/solution surface —
  nothing else: no EC2, no S3, no IAM, no account access of any other
  kind), and
- optionally pins the **catalog** (AWS production vs. AWS's isolated
  Sandbox test catalog) and an **external ID**, if you want the extra
  hardening.

The end customer accounts on your opportunities are never accessed — an
opportunity record *mentions* a customer's AWS account ID; the agent has
no permissions that could reach it.

## Templates

### `templates/opportunity-manager-role.yaml` — default model

One shared `Namazu-CoSell-Opportunity-Manager` role, attributed to one named user
via the `AuthorizedUser` tag + source-identity match. Use this when one
person (e.g. your account manager) is the co-selling contact.

| Parameter | Required | What it does |
|---|---|---|
| `AuthorizedUser` | yes | The person this role is attributed to — becomes the source identity and the role's tag |
| `RoleName` | no | The role's name (default `Namazu-CoSell-Opportunity-Manager`). The prefix is fixed — it keeps the access identifiable as ours and the agent's side gates assumes to that namespace — but you may append a hyphenated suffix (e.g. `…-Manager-Prod`) if the default collides or your conventions call for one |
| `NamazuAccountId` | no | The Namazu hosting account to trust (default: Namazu Studios' production account — your contact will confirm) |
| `ExternalId` | no | Adds an `sts:ExternalId` condition if you want extra confused-deputy protection |
| `EnforceSessionName` | no | Pins the assume-role session name to `<user>-session` |
| `ResourceScope` | no | Narrows the permission policy's `Resource` (default `*`) |
| `CatalogPin` | no | Pins the role to one Partner Central catalog (`Sandbox` for trials, `AWS` for production) |

### `templates/per-user-roles.yaml` — strict-accountability variant

One `Namazu-CoSell-Opportunity-Manager-<user>` role **per named user** from the
`Users` list (a comma-delimited list, e.g. `"peter,maria"`). Same trust
and permission shape as above, per person — use this when several people
work co-selling and you want each one's access to be an independent,
separately revocable role.

| Parameter | Required | What it does |
|---|---|---|
| `Users` | yes | The individuals to create roles for — each becomes its own role, its `AuthorizedUser` tag, and its source identity (2–30 characters at the default prefix) |
| `RoleNamePrefix` | no | The prefix of the per-user role names (default `Namazu-CoSell-Opportunity-Manager`, yielding `…-Manager-<user>`). The prefix is fixed for the same reasons as the shared template's `RoleName` — identifiability, and the Namazu side gates its assumes to that namespace — but a hyphenated suffix is allowed (e.g. `…-Manager-Prod` yields `…-Manager-Prod-<user>` roles) |
| `NamazuAccountId` | no | The Namazu hosting account to trust (default: Namazu Studios' production account — your contact will confirm) |
| `ExternalId` | no | Adds an `sts:ExternalId` condition to every role if you want extra confused-deputy protection |
| `EnforceSessionName` | no | Pins each role's assume-role session name to `<user>-session` |
| `ResourceScope` | no | Narrows the permission policy's `Resource` (default `*`) |
| `CatalogPin` | no | Pins every role to one Partner Central catalog (`Sandbox` for trials, `AWS` for production) |

The `examples/` directory carries the plain policy JSON these templates
embed (the trust policy, the permission policy, and the per-user policy
shape) if you want to review the exact IAM documents or recreate them by
hand.

## Quick start: the interactive manager

`manage-access.sh` manages the per-user model end to end — add a user
(it creates or updates the CloudFormation stack), list the current users
with their role ARNs, remove a user, or tear the whole stack down:

```bash
./manage-access.sh                      # menu: add / list / remove / delete
./manage-access.sh --region us-east-1   # or --stack-name to manage another stack
```

Requirements: bash and the AWS CLI, authenticated as a principal allowed
to create IAM roles in the account linked to your Partner Central
account. Nothing else — no `jq`. The script re-passes every existing
stack parameter on each update, so optional settings chosen at creation
(an external ID, a catalog pin) are preserved when users are added or
removed. After each change it prints the role ARNs to hand to your
Namazu contact.

For the single-user shared-role model — or if you prefer not to use the
script — the direct deploy flow follows.

## Using a template

From your AWS account **linked to Partner Central** (the account
alliance-lead/cloud-administrator uses for Partner Central — see AWS's
[account linking](https://docs.aws.amazon.com/partner-central/latest/getting-started/account-linking.html)
docs):

```bash
aws cloudformation deploy \
  --stack-name namazu-coselling-access \
  --template-file templates/opportunity-manager-role.yaml \
  --parameter-overrides AuthorizedUser=peter \
  --capabilities CAPABILITY_NAMED_IAM
```

(Or upload the template in the CloudFormation console. `CAPABILITY_NAMED_IAM`
is required because the stack creates a named IAM role.)

When the stack completes, the stack's **Outputs** show the role ARN.
Give that to your Namazu contact, along with the `ExternalId` value if
you set one — they wire it into the agent deployment on their side. That
configuration lives with Namazu; nothing further runs in your account.

## Prerequisites

- The AWS account you deploy from must be the one linked to your
  Partner Central account (opportunity permissions only function there).
- An IAM principal allowed to create roles and attach inline policies.

## Support

Questions or something not working? Contact your Namazu Studios
representative.

## License

MIT — see [LICENSE](LICENSE).
