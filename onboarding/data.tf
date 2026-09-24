data "aws_caller_identity" "current" {

}

data "aws_route53_zone" "main" {
  name         = "olrstech.com."
  private_zone = false

}

data "aws_instance" "dc" {

  filter {
    name   = "tag:Name"
    values = ["olrs-dc01"]

  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]

  }


}
data "aws_iam_instance_profile" "dc" {
  name = data.aws_instance.dc.iam_instance_profile
}
