variable "bootstrap_admin_sub" {
  type        = string
  default     = ""
  description = "Immutable Cognito sub of the initial owner, set after creating that user. Empty denies everyone access."

}

variable "owner_email" {
  type        = string
  default     = "admin@olrstech.com"
  description = "Owner display email. Authorization always uses bootstrap_admin_sub, never this email."

}

variable "provisioning_enabled" {
  type        = bool
  default     = false
  description = "Enable only after the PowerShell adapter and server prerequisites have been verified."

}
variable "graph_tenant_id" {
  type    = string
  default = ""
  validation {
    condition     = var.graph_tenant_id == "" || can(regex("^[a-fA-F0-9-]{36}$", var.graph_tenant_id))
    error_message = "Use the Entra directory tenant ID."
  }
}
variable "graph_client_id" {
  type    = string
  default = ""
  validation {
    condition     = var.graph_client_id == "" || can(regex("^[a-fA-F0-9-]{36}$", var.graph_client_id))
    error_message = "Use the dedicated onboarding app client ID."
  }
}
variable "graph_certificate_thumbprint" {
  type    = string
  default = ""
  validation {
    condition     = var.graph_certificate_thumbprint == "" || can(regex("^[a-fA-F0-9]{40}$", var.graph_certificate_thumbprint))
    error_message = "Use the onboarding certificate thumbprint."
  }
}

variable "adapter_path" {
  type    = string
  default = "C:\\ProgramData\\OLRS\\Onboarding\\Invoke-OnboardingAdapter.ps1"
  validation {

    condition     = can(regex("^[A-Za-z]:\\\\[A-Za-z0-9_ .\\\\-]+\\.ps1$", var.adapter_path))
    error_message = "Use an absolute Windows .ps1 path with safe characters."

  }


}

