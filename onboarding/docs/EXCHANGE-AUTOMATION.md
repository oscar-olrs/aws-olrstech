# Exchange mailbox automation setup

Status: certificate connection verified; Simple sections interface and restricted asynchronous mailbox worker implemented. Deployment verification recorded below.

1. Register **OLRS Exchange Mailbox Automation** in Entra, single tenant, no redirect URI.
2. Add Office 365 Exchange Online **Application** permission `Exchange.ManageAsApp` and grant administrator consent. Do not assign Exchange Administrator or Global Administrator directory roles.
3. Run ../scripts/Create-ExchangeAutomationCertificate.ps1 on the Windows worker as Administrator. Upload only its public certificate to the dedicated app. Keep the non-exportable private key on the worker.
4. Obtain the client ID and the Enterprise application's Object ID. These are public identifiers. The App registration Object ID is NOT the Enterprise application Object ID.
5. Run ../scripts/Configure-ExchangeMailboxAutomation.ps1 in connected administrator Exchange Online PowerShell with those two IDs. Its custom role and recipient write scope limit mailbox delegation to IT, HR, Safety, Sales and Payroll. Recipient reads can resolve employee trustees across the tenant.
6. Test certificate authentication using the certificate object from LocalMachine and the tenant's PRIMARY onmicrosoft.com domain:

```powershell
$certificate = Get-Item "Cert:\LocalMachine\My\<certificate-thumbprint>"
Connect-ExchangeOnline -AppId '<client-id>' -Organization '<primary-domain>.onmicrosoft.com' -Certificate $certificate -ShowBanner:$false
```

Validate allowed commands, target mailbox scope, and rejection for unrelated mailboxes before portal enablement. Do not grant users mailbox access as a connection test.

Next implementation: restricted SSM worker, mailbox readiness polling, user lookup, requested/confirmed delegation state, backend administrator permission enforcement, and form/UI integration. Full Access is required for automapping. Send on Behalf must be explicitly selected alongside Full Access. Review direct grants within the administrator’s allowed mailboxes before changing them; record requester and outcomes. Mailbox licensing is not automated by this setup.

Microsoft reference: https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2

## September 14 implementation

Dedicated app: 3fbbf739-8989-4d09-9c7c-4b00f3ccd7bb. Enterprise application object: 35c99441-b2bf-4b2b-9235-c6c3a2abd579. Tenant: OlrsTech.onmicrosoft.com. Certificate thumbprint: 80894C4AF9D30F38DEB059E227F63384D84C6C10; expires September 14, 2027. Private key remains non-exportable on the worker.

Portal: employee details followed by optional shared mailbox access, review, single submit. Users automatically browses the managed Users OU in pages of 25, refreshes pending tasks, inspects an employee, and reviews changes. Employee profile editing requires manage_users and uses a recent snapshot to reject stale updates. Protected accounts cannot be edited. The API requires manage_mailboxes plus per-administrator allowedMailboxes; super administrators have all five. Existing administrators do not silently gain this permission. Role presets are edited under Roles & permissions.

Mailbox tasks use a separate pinned SSM document, protected server script, DynamoDB state and user lock, and a protected apply journal. Reads do not mutate Exchange. Account creation success queues access; mailbox-not-ready reads retry every three minutes for up to 24 hours without recreating the account. No licensing is assigned. Uncertain dispatches or partial writes require manual IT review; locks and journals intentionally prevent automatic replay. Do not clear these without examining the original command and live grants.

Existing direct Full Access and Send on Behalf grants can be changed after inspection and explicit review, within the administrator’s allowed mailbox list. Existing automapping cannot be inferred; access is not removed/re-added solely to change automapping. Group-derived access is not modified or represented as a direct app-managed grant. Send As is outside this feature. Send on behalf changes use additive/removal syntax to preserve other delegates.

Checks: 30 Python security/state tests, mocked browser employee selection and Users editing at 1280/390 widths, existing login/MFA/reset browser suite, mocked PowerShell add/remove/waiting paths, Terraform validation. Live server Search and Inspect succeeded; inspected employee mailbox was not ready. No real employee was created and no live user mailbox permission was changed for testing. Real mailbox-write completion remains to be observed on an authorized onboarding submission.

Deployment completed: 6 resources added, 6 updated, none destroyed. Published mailbox-ui.js matches tested source. Lambda Active/Successful with mailbox document version 1. Unauthenticated mailbox endpoint returned HTTP 401.
