output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "instance_id" {
  description = "ID of the private EC2 instance"
  value       = aws_instance.this.id
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group that receives the VPC Flow Logs"
  value       = module.vpc.flow_log_group_name
}
