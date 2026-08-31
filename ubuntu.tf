# --------------------------------------------------
# Ubuntu AMI
# --------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


# --------------------------------------------------
# OLRS Tailscale / NAT Router
# --------------------------------------------------

resource "aws_instance" "ts01" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  subnet_id              = aws_subnet.edge_a.id
  private_ip             = "10.0.10.10"
  vpc_security_group_ids = [aws_security_group.ts01.id]
  iam_instance_profile   = aws_iam_instance_profile.ts01.name



  # Required because this EC2 instance will route
  # traffic for other systems.
  source_dest_check = false

  lifecycle {
    ignore_changes = [ami]
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-ts01"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Role        = "Tailscale-NAT-Router"
  }
}


