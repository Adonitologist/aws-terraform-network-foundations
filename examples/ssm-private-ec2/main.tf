locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name = var.project
}

# No ingress rules at all (including port 22). Outbound HTTPS only, which
# covers SSM endpoints and package mirrors through the NAT gateway.
resource "aws_security_group" "instance" {
  name        = "${var.project}-instance-sg"
  description = "Private instance: no inbound, outbound HTTPS only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.project}-instance-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.instance.id
  description       = "Outbound HTTPS for SSM and package mirrors"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "ssm" {
  name = "${var.project}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ec2-ssm-profile"
  role = aws_iam_role.ssm.name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  volume_tags = local.common_tags

  tags = {
    Name = "${var.project}-instance"
  }

  depends_on = [aws_iam_role_policy_attachment.ssm]
}
