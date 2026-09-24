# Connecting the existing PowerShell workflow

The original script at C:\Users\Administrator\Desktop\Onboarding App.ps1 is left
untouched. ../scripts/Invoke-OnboardingAdapter.ps1 adapts its AD creation, group verification
and Microsoft Graph Cloud Sync provisionOnDemand steps for noninteractive use.
This is not an ADSync delta-cycle implementation.

## Windows prerequisites

Install ActiveDirectory, AWS.Tools.SecretsManager, Microsoft.Graph.Authentication
and Microsoft.Graph.Applications so LocalSystem can load them (AllUsers scope).
Copy ../scripts/Invoke-OnboardingAdapter.ps1 to C:\ProgramData\OLRS\Onboarding. Run the certificate
helper as Administrator: it creates the protected journal directory and a
nonexportable certificate in LocalMachine\My. Retain the thumbprint and plan
certificate renewal before its one-year expiry.

Run ../scripts/Register-OnboardingEntraApp.ps1 interactively, supplying the thumbprint.
It requires administrator sign-in and consent, creates a dedicated single-tenant
application and grants the Graph synchronization application permission.
Synchronization.ReadWrite.All is tenant-wide; the portal fixes the target job,
OU and sync group. A certificate prevents storing a Graph client secret in the
portal. No employee gets this application permission.

Create a dedicated AD onboarding service account. Delegate only user creation,
required user property writes/password reset in
OU=Users,OU=OLRS,DC=ad,DC=olrstech,DC=com and writing the member attribute of
Entra-Sync-Users. Do not use Domain Admin credentials. Populate the Terraform-created
olrs-onboarding-ad-credential secret securely with JSON fields username and
password. Do not paste these credentials into chat or put them in tfvars.

The server reads credentials through its existing instance profile, with a new
IAM policy conditioned on this Windows instance ARN. The Ubuntu instance using
the same role cannot use this policy. The API can read employee temporary
password secrets but cannot read the delegated AD account credential secret.

## Password handling

The API generates a strong temporary password per employee request, stored only
in Secrets Manager. The Windows adapter reads it directly, and creates the AD
account with ChangePasswordAtLogon=true, preserving the original behavior.
After successful script completion, the submitting admin or a super admin can
reveal it once, within 24 hours. Deliver it through your approved secure channel.
The application never stores it in request records or command parameters.
After 24 hours, the scheduled task schedules secret deletion with a seven-day
recovery window; the delegated service-account secret is not deleted by it.
If a reveal fails after the one-time lock, IT must reset the AD password.

Validate how your Cloud Sync configuration handles forced password change and
password hash synchronization before relying on a first sign-in to Microsoft 365.
Graph HTTP success is parsed for the actual provision-on-demand outcome; even a
successful outcome does not confirm a Microsoft 365 license or mailbox exists.

## Enable and verify

Set graph_tenant_id, graph_client_id and graph_certificate_thumbprint using the
non-secret identifiers from the registration helper. Keep provisioning_enabled
false until module loading, certificate access, delegated AD permissions and
secret retrieval have been verified under the actual SSM execution identity.
Then review/apply the enabling plan and use one designated test account.
Verify AD attributes, group membership, Graph outcome and M365 readiness separately.
Partial failures and existing usernames require manual IT review; this application
does not silently modify existing users or retry partially completed creation.

References:
- https://learn.microsoft.com/en-us/graph/api/synchronization-synchronizationjob-provisionondemand?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html
