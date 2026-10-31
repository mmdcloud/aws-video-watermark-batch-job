output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "s3_endpoint_id" {
  value = try(aws_vpc_endpoint.s3[0].id, null)
}
