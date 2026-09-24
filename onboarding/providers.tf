terraform {

  required_version = ">= 1.10.0"
  required_providers {

    aws = {
      source = "hashicorp/aws", version = "~> 6.0"
    }

    archive = {
      source = "hashicorp/archive", version = "~> 2.7"
    }


  }

  # Separate state: never apply this component with the lab's state key.



}

provider "aws" {
  region  = "us-west-2"
  profile = "olrstech-admin"
  default_tags {
    tags = {
      Project = "olrs", Environment = "lab", Component = "onboarding", ManagedBy = "Terraform"
    }

  }


}

provider "aws" {
  alias   = "certificate"
  region  = "us-east-1"
  profile = "olrstech-admin"

}

