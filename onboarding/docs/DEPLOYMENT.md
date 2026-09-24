# Current deployment — 2026-09-13

Portal: https://onboarding.olrstech.com

Deployed AWS component: CloudFront/private S3, HTTPS/DNS, Cognito administrator
pool, JWT-protected API, Lambda, DynamoDB, queue and scheduled status polling.
The existing lab infrastructure is referenced from a separate Terraform state
key, lab/onboarding/terraform.tfstate.

Owner account: admin@olrstech.com. Its immutable subject is configured in the
ignored terraform.tfvars. Cognito requested delivery of the account invitation.
The owner must complete initial password setup and required authenticator MFA.

On the Windows server:
- Existing desktop onboarding script is preserved.
- Protected adapter, Graph registration helper and public certificate are in
  C:\ProgramData\OLRS\Onboarding.
- Microsoft Graph modules are installed for the SSM execution identity.
- Certificate thumbprint: ECB7752F9F729364498BF8EF9596501B1A7BE72B.
- svc-olrs-onboard was created as a dedicated technical AD account, with explicit
  creation/property/password-reset permissions in the fixed employee OU and
  member-write permission on Entra-Sync-Users. It was not added to that sync group.
- Its generated credential is held in olrs-onboarding-ad-credential. Coordinate
  future service credential rotation in AD and Secrets Manager. Automatic AD
  password expiry is disabled for this technical account.
- The temporary bootstrap secret-write permission was removed after setup.

Employee provisioning is ENABLED after the designated Chris Ronaldo / cronaldo
integration test. Department was set to Test. Request ID:
738732f5-55e4-496e-9a0a-281628a78721. The request was submitted directly to the
backend under the owner identity; this does not verify browser sign-in.

The user registered and approved OLRS Onboarding Automation:
- Tenant ID: 66a779ef-28f4-4e14-b007-54bccfa9c67e
- Client ID: d7d50fc0-0df9-45f2-add2-5517596191ae
- Uploaded public certificate; Graph application Synchronization.ReadWrite.All
  admin consent completed by the user. Certificate/job read access was verified.

The test discovered incompatible AWS/Graph assemblies in Windows PowerShell.
Secret retrieval now runs in a separate child process, capturing credentials only
in memory; Graph stays in the parent process. Both failed attempts were verified
not to have created an AD account or journal before retrying the same request.
Successful SSM command: 013c060d-4676-4583-b17b-a6d03675515e.
AD creation, sync-group membership and provision-on-demand completed successfully.
M365 licensing and mailbox readiness remain unverified.

Remaining: complete owner browser sign-in/MFA and validate designated HR/IT
administrator permissions in the live portal. Browser automation for Entra was
blocked by an administrator-policy verification failure; Microsoft setup was
completed manually by the user.

Verified: 17 backend tests; desktop/mobile browser checks with test responses;
Windows adapter syntax and prerequisite checks; successful AD bootstrap and
credential authentication; live HTTPS/configuration and anonymous API rejection.
Backend employee provisioning is verified; authenticated Cognito/MFA remains unverified.
