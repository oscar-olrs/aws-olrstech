resource "aws_security_group" "ts01" {
  name        = "${var.project_name}-sg-ts"
  description = "Security group for OLRS Tailscale subnet router and NAT instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow traffic from OLRS VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-sg-ts"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}


########### Windows Server ##################

resource "aws_security_group" "dc01" {
  name        = "${var.project_name}-sg-dc01"
  description = "Security group for OLRS domain controller"
  vpc_id      = aws_vpc.main.id

  # RDP from the VPC.
  # Tailscale subnet routing through olrs-ts01 will allow us to
  # securely reach the DC without exposing RDP to the Internet.
  ingress {
    description = "RDP from VPC"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  ingress {
    description = "SSH from Tailscale router"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.10.10/32"]
  }

  # Allow outbound connectivity for Windows Update,
  # Microsoft services, SSM, etc.
  egress {
    description = "Allow outbound IPv4"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-sg-dc01"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

