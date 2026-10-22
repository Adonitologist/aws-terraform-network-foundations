variable "aws_region" {
  description = "AWS region where the example is deployed"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as resource name prefix and as the Project tag"
  type        = string
  default     = "alb-asg"
}

variable "environment" {
  description = "Environment name, used as the Environment tag"
  type        = string
  default     = "dev"
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the load balancer on port 80. Required, no default, any /0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "At least one CIDR block is required."
  }

  validation {
    condition     = alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid CIDR block."
  }

  validation {
    condition     = !anytrue([for c in var.allowed_ingress_cidrs : endswith(c, "/0")])
    error_message = "Open-to-the-world CIDRs (0.0.0.0/0 or any /0) are not allowed."
  }
}
