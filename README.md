# Enterprise AWS Multi-Tier VPC & Secure Compute Architecture

![Terraform CI](https://github.com/Adonitologist/aws-vpc-networking-project/actions/workflows/terraform-ci.yml/badge.svg)
![Terraform](https://img.shields.io/badge/Terraform->=1.5.0-623CE4?logo=terraform)
![AWS Provider](https://img.shields.io/badge/AWS_Provider-~>5.0-FF9900?logo=amazon-aws)

Infrastructure-as-Code (IaC) implementation of a production-grade, highly secure AWS network architecture using Terraform. This repository demonstrates core enterprise networking principles including subnets isolation, centralized egress via NAT Gateway, network observability using VPC Flow Logs, zero-SSH management via AWS Systems Manager (SSM), and automated CI/CD static security analysis.

## Architecture Overview

```text
+-------------------------------------------------------------------------+
| AWS Region: us-east-1                                                   |
| VPC: 10.0.0.0/16 (VPC Flow Logs -> CloudWatch)                          |
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  | Public Subnet: 10.0.1.0/24 (AZ: us-east-1a)                      |  |
|  |                                                                   |  |
|  |  +------------------+         +-------------------------------+   |  |
|  |  | Internet Gateway | <-----> | NAT Gateway (Elastic IP)      |   |  |
|  |  +------------------+         +-------------------------------+   |  |
|  +-----------------------------------------------+-------------------+  |
|                                                  |                      |
|                                                  | (Private Egress)     |
|                                                  v                      |
|  +-------------------------------------------------------------------+  |
|  | Private Subnet: 10.0.2.0/24 (AZ: us-east-1a)                    |  |
|  |                                                                   |  |
|  |  +-------------------------------------------------------------+  |  |
|  |  | EC2 Instance (Amazon Linux 2023 / t3.micro)                 |  |  |
|  |  | - No Public IP                                              |  |  |
|  |  | - Managed via AWS Systems Manager (SSM Core IAM Role)       |  |  |
|  |  | - IMDSv2 Enforced | Encrypted EBS Root Volume               |  |  |
|  |  +-------------------------------------------------------------+  |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+



Key Technical Features

    Multi-Tier Subnet Topology: Complete separation between public ingress/egress resources and isolated private compute workloads.

    Network Observability: AWS VPC Flow Logs captured and published to Amazon CloudWatch Logs with a 7-day retention policy for security auditability.

    Zero-SSH Bastionless Management: Private EC2 instances operate without public IP addresses and with SSH (port 22) disabled. Remote administration is secured via AWS SSM Session Manager.

    Compute Hardening:

        Enforced IMDSv2 (Instance Metadata Service v2) to prevent SSRF vulnerabilities.

        Encrypted EBS root volume with gp3 specification.

    Automated CI/CD Pipeline: GitHub Actions workflow executing formatting checks (terraform fmt), syntax validation (terraform validate), and static security scanning (tfsec).

Repository Structure
Plaintext

aws-vpc-networking-project/
├── .github/
│   └── workflows/
│       └── terraform-ci.yml       # GitHub Actions CI pipeline
├── .gitignore                     # Exclusion rules for state and sensitive files
├── main.tf                        # Core network, compute, flow logs, and IAM resources
├── outputs.tf                     # Infrastructure output attributes
├── providers.tf                   # AWS provider and default resource tags
├── README.md                      # Project documentation
├── terraform.tfvars               # Infrastructure variable values
└── variables.tf                   # Input variable declarations

Quickstart Guide
1. Prerequisites

    Terraform >= 1.5.0

    AWS CLI configured with valid IAM credentials.

2. Initialization & Validation
Bash

git clone [https://github.com/Adonitologist/aws-vpc-networking-project.git](https://github.com/Adonitologist/aws-vpc-networking-project.git)
cd aws-vpc-networking-project
terraform init
terraform validate

3. Deployment
Bash

terraform plan
terraform apply -auto-approve

Cost Control & Resource Cleanup Protocol

To maintain zero ongoing AWS infrastructure charges after testing:
Bash

terraform destroy -auto-approve


