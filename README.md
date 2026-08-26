# OLRS AWS Hybrid Identity & Secure File Storage Lab

This project is an enterprise-style AWS lab built primarily with Terraform. It integrates Microsoft Entra ID, AWS IAM Identity Center, self-managed Active Directory on Windows Server EC2, Tailscale, Route 53, Amazon S3 File Gateway, and Amazon S3.

## Current Status

Phase 0 — Local AWS/Terraform Environment

## Initial Architecture Goals

- AWS VPC: `10.0.0.0/16`
- Microsoft Entra ID for cloud identity
- AWS IAM Identity Center for AWS SSO
- Self-managed Active Directory on Windows Server EC2
- Amazon Route 53 for public DNS
- Tailscale for secure remote access
- S3 File Gateway for authenticated SMB access
- Amazon S3 for file storage
- Terraform for AWS infrastructure deployment
