# Flowing Blue email templates

Selected design: Flowing Blue. Sender/reply-to: onboarding@olrstech.com.

admin-invitation.html: invitation only for administrators who create and onboard users.
account-created.html: employee account creation notice for the employee and authorized administrator.

Variables use {{name}} placeholders. HTML-escape all text values; validate logo and activation URLs before inserting them. Use externally hosted HTTPS logo URLs in emails, not embedded data URLs. Provide plain-text alternatives. Never include employee passwords in notification emails.

These are saved templates; they are not yet wired to delivery. The shared mailbox, sender authorization, recipient collection (including a deliverable employee contact address), and application email integration remain to be completed. Full Access alone does not grant application sending rights.
