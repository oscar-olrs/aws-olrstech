# OLRS Tech onboarding application

Separate Terraform root for https://onboarding.olrstech.com. Its remote state is
`olrs-terraform-state/lab/onboarding/terraform.tfstate`; the parent project uses
`lab/terraform.tfstate`. Run onboarding Terraform commands from this folder.

## Layout

- `api/`: Lambda backend and mailbox/user orchestration.
- `site/`: browser application, styles, and published assets.
- `emails/`: canonical email templates; Terraform packages account-created.html into Lambda.
- `scripts/`: Windows AD/Exchange automation and setup scripts.
- `docs/`: deployment, integration, and Exchange setup guides.
- `certificates/`: public certificate copies only; private keys remain on the Windows server.
- `tests/`: API and browser checks.
- `backend.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `data.tf`: configuration.
- `auth.tf`, `api.tf`, `automation.tf`, `storage.tf`, `website.tf`, `email.tf`: AWS resources.
- `outputs.tf`: exported values.

## Workflow

Authenticate the `olrstech-admin` profile, then run:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

Review every plan before applying. Server script installation and Microsoft
consent are separate from Terraform; moving local scripts does not change their
installed Windows paths. See [integration](docs/INTEGRATION.md),
[Exchange automation](docs/EXCHANGE-AUTOMATION.md), and [deployment](docs/DEPLOYMENT.md).

The deployed app supports employee onboarding, OU user browsing/profile editing,
shared mailbox delegation, administrator permissions, and SES notifications.
The Windows worker must be online. Exchange mailbox availability depends on
licensing and provisioning; license assignment/purchasing is not automated.
Partial/ambiguous failures require review rather than blind retries.

## Checks

```bash
PYTHONPATH=api python3 -m unittest discover -s tests
node tests/mailbox-ui.cjs
node tests/journey-login.cjs
```

Temporary `.build/`, provider caches, saved plans, and local variable files are
ignored by Git. Public certificates may be backed up; never commit private keys.
