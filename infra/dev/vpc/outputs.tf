output "vpc_id" {
  description = "ID of the development VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "availability_zones" {
  description = "Availability zones used by all three tiers."
  value       = module.vpc.azs
}

output "public_subnet_ids" {
  description = "Public/edge subnet IDs for internet-facing load balancers and NAT gateways."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private application subnet IDs used by EKS nodes and internal load balancers."
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "Isolated database subnet IDs with no default route to an IGW or NAT gateway."
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "RDS database subnet group spanning all database subnets."
  value       = module.vpc.database_subnet_group_name
}

output "private_route_table_ids" {
  description = "Route table IDs for the application tier."
  value       = module.vpc.private_route_table_ids
}

output "database_route_table_ids" {
  description = "Isolated route table IDs for the database tier."
  value       = module.vpc.database_route_table_ids
}

output "nat_gateway_public_ips" {
  description = "Stable egress addresses for allow-listing application-tier traffic."
  value       = module.vpc.nat_public_ips
}

output "vpc_flow_log_kms_key_arn" {
  description = "KMS key ARN used to encrypt VPC Flow Logs."
  value       = aws_kms_key.flow_logs.arn
}
