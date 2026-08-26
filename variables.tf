variable "aws_region" {
  description = "AWS region used for the OLRS Tech hybrid identity lab"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Name used to identify resources belonging to this project"
  type        = string
  default     = "olrs"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "lab"
}
