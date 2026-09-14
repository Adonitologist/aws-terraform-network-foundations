output "vpc_id" {
  description = "ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID de la subred pública"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID de la subred privada"
  value       = aws_subnet.private.id
}

output "nat_gateway_ip" {
  description = "Dirección IP pública del NAT Gateway"
  value       = aws_eip.nat_eip.public_ip
}

output "private_instance_id" {
  description = "ID de la instancia EC2 privada"
  value       = aws_instance.app_server.id
}