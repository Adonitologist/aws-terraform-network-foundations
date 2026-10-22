variable "aws_region" {
  description = "AWS region where the example is deployed"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as resource name prefix and as the Project tag"
  type        = string
  default     = "ssm-private-ec2"
}

variable "environment" {
  description = "Environment name, used as the Environment tag"
  type        = string
  default     = "dev"
}
