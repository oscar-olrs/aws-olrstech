# SES delivery setup — 2026-09-14

Sender/reply-to: onboarding@olrstech.com. Microsoft 365 receives replies.
SES domain olrstech.com is verified with successful DKIM in us-west-2.
Production-access request was submitted; review is PENDING. email_enabled remains
false until production access is approved. No test emails were sent.

After approval, set email_enabled=true in terraform.tfvars, plan and apply.
This switches Cognito invitations/password recovery to SES with the branded
administrator invitation and enables account-created notices.

New onboarding requests store the submitting administrator email and optionally
an existing employee contact email. Notices are eligible only after successful
script completion. The new employee work mailbox is not assumed deliverable.
Existing historical requests are not backfilled. Each recipient is claimed before
sending; ambiguous or failed sends are recorded as Needs review, with no automatic
retry. Accepted means SES accepted the message, not inbox delivery. No bounce or
complaint processor is installed yet; SES account suppression should be monitored
before production enablement. No employee passwords are included in notices.
Cognito administrator invitations retain the initial temporary-password flow.

Tests: 20 backend tests passed, including disabled sending, HTML escaping and
recipient scoping, and duplicate-send prevention. JavaScript syntax passed.
Live delivery remains unverified pending SES production approval.
