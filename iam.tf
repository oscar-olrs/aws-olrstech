resource "aws_iam_role" "ts01_ssm" {
  name = "${var.project_name}-ts01-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ts01-ssm-role"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "ts01_ssm" {
  role       = aws_iam_role.ts01_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ts01" {
  name = "${var.project_name}-ts01-profile"
  role = aws_iam_role.ts01_ssm.name
}