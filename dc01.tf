data "aws_ami" "windows_server" {
  most_recent = true
  owners      = ["801119661308"] # Amazon

  filter {
    name   = "name"
    values = ["Windows_Server-2025-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}



resource "aws_instance" "dc01" {
  ami           = data.aws_ami.windows_server.id
  instance_type = "t3.medium"

  subnet_id                   = aws_subnet.private_a.id
  private_ip                  = "10.0.20.10"
  associate_public_ip_address = false

  vpc_security_group_ids = [
    aws_security_group.dc01.id
  ]

  iam_instance_profile = aws_iam_instance_profile.ts01.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name        = "${var.project_name}-dc01"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Role        = "Domain-Controller"
  }
}
