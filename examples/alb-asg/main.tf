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

# --- Security groups ---
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Load balancer: HTTP from allowed CIDRs, outbound to instances only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.project}-alb-sg"
  }
}

resource "aws_security_group" "instance" {
  name        = "${var.project}-instance-sg"
  description = "Instances: HTTP from the load balancer, outbound HTTPS only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.project}-instance-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from an allowed CIDR"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_instances" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to instances"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.instance.id
}

resource "aws_vpc_security_group_ingress_rule" "instance_http" {
  security_group_id            = aws_security_group.instance.id
  description                  = "HTTP from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "instance_https" {
  security_group_id = aws_security_group.instance.id
  description       = "Outbound HTTPS for package mirrors through the NAT gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Load balancer ---
# The load balancer is public by design; access is limited by allowed_ingress_cidrs.
#tfsec:ignore:aws-elb-alb-not-public
resource "aws_lb" "this" {
  name                       = "${var.project}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = module.vpc.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "this" {
  name                 = "${var.project}-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# HTTP only: HTTPS needs a certificate and a domain, which are out of scope.
#tfsec:ignore:aws-elb-http-not-used
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# --- Instances ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_launch_template" "this" {
  name_prefix            = "${var.project}-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  update_default_version = true

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.instance.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.project}-instance" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  # The page shows the instance id and availability zone, read with IMDSv2.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y nginx
    TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    echo "instance-id=$INSTANCE_ID az=$AZ" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT
  )
}

resource "aws_autoscaling_group" "this" {
  name                      = "${var.project}-asg"
  min_size                  = 2
  desired_capacity          = 2
  max_size                  = 3
  min_elb_capacity          = 2
  vpc_zone_identifier       = module.vpc.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }
}
