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