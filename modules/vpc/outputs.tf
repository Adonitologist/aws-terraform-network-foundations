output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

# depends_on makes callers wait for a usable network: instances that install
# packages at first boot (dnf) can otherwise start before the NAT route exists.
output "public_subnet_ids" {
  description = "IDs of the public subnets, one per availability zone"
  value       = aws_subnet.public[*].id
  depends_on  = [aws_route_table_association.public, aws_internet_gateway.this]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per availability zone"
  value       = aws_subnet.private[*].id
  depends_on  = [aws_route_table_association.private, aws_nat_gateway.this]
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group that receives the VPC Flow Logs"
  value       = aws_cloudwatch_log_group.flow_logs.name
}
