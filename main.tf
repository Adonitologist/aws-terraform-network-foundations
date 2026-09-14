# --- 1. Redes Principales ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.environment}-enterprise-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment}-public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.environment}-private-subnet"
  }
}

# --- 2. Gateways & Tablas de Enrutamiento ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment}-igw"
  }
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"

  tags = {
    Name = "${var.environment}-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.environment}-nat-gateway"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${var.environment}-private-rt"
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# --- 3. VPC Flow Logs (Observabilidad y Seguridad) ---
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.environment}-flow-logs"
  retention_in_days = 7
}

resource "aws_iam_role" "vpc_flow_log_role" {
  name = "${var.environment}-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_log_policy" {
  name = "${var.environment}-vpc-flow-log-policy"
  role = aws_iam_role.vpc_flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Effect   = "Allow"
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.vpc_flow_log_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
}

# --- 4. Computo Privado y SSM ---
resource "aws_security_group" "private_sg" {
  name        = "${var.environment}-private-instance-sg"
  description = "Strict security group for private application instance"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow outbound HTTPS traffic for updates and SSM"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment}-private-sg"
  }
}

resource "aws_iam_role" "ssm_role" {
  name = "${var.environment}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.environment}-ec2-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_instance" "app_server" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private.id
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  user_data_replace_on_change = true

  vpc_security_group_ids = [aws_security_group.private_sg.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y nginx
              systemctl enable nginx
              systemctl start nginx

              TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
              AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

              cat <<HTML > /usr/share/nginx/html/index.html
              <!DOCTYPE html>
              <html>
              <head>
                  <title>Enterprise Private Subnet Node</title>
                  <style>
                      body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #0f172a; color: #f8fafc; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; position: relative; }
                      .card { background: #1e293b; padding: 2.5rem; border-radius: 12px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); border: 1px solid #334155; max-width: 500px; width: 100%; position: relative; }
                      h1 { color: #38bdf8; font-size: 1.5rem; margin-top: 10px; }
                      .badge { background: #0284c7; color: white; padding: 4px 8px; border-radius: 4px; font-size: 0.8rem; font-weight: bold; }
                      .info-item { margin: 12px 0; font-size: 0.95rem; color: #cbd5e1; }
                      .info-item strong { color: #f1f5f9; }
                      .footer { border-top: 1px solid #334155; margin-top: 20px; padding-top: 15px; font-size: 0.85rem; color: #94a3b8; text-align: center; }
                      
                      .github-btn {
                          position: fixed;
                          top: 24px;
                          left: 24px;
                          width: 44px;
                          height: 44px;
                          background: #1e293b;
                          border: 1px solid #334155;
                          border-radius: 8px;
                          display: flex;
                          justify-content: center;
                          align-items: center;
                          color: #cbd5e1;
                          text-decoration: none;
                          box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                          transition: all 0.2s ease-in-out;
                      }
                      .github-btn:hover {
                          background: #0284c7;
                          color: #ffffff;
                          border-color: #38bdf8;
                          transform: translateY(-2px);
                      }
                      .github-btn svg {
                          width: 22px;
                          height: 22px;
                          fill: currentColor;
                      }
                  </style>
              </head>
              <body>
                  <a href="https://github.com/Adonitologist?tab=repositories" target="_blank" class="github-btn" title="GitHub Repositories">
                      <svg viewBox="0 0 24 24">
                          <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/>
                      </svg>
                  </a>
                  <div class="card">
                      <span class="badge">AWS PRIVATE SUBNET</span>
                      <h1>Node Status: Operational</h1>
                      <div class="info-item"><strong>Instance ID:</strong> $INSTANCE_ID</div>
                      <div class="info-item"><strong>Availability Zone:</strong> $AZ</div>
                      <div class="info-item"><strong>Access Mode:</strong> Zero-SSH (SSM Session Manager)</div>
                      <div class="info-item"><strong>Egress Path:</strong> Private NAT Gateway</div>
                      <div class="footer">
                          Architected & Managed via Terraform by <strong>Adonitologist</strong>
                      </div>
                  </div>
              </body>
              </html>
              HTML
              EOF

  tags = {
    Name = "${var.environment}-private-app-server"
  }
}