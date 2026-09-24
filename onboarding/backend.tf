terraform {
  backend "s3" {

    bucket       = "olrs-terraform-state"
    key          = "lab/onboarding/terraform.tfstate"
    region       = "us-west-2"
    profile      = "olrstech-admin"
    encrypt      = true
    use_lockfile = true

  }
}
