data "aws_region" "current" {}

module "vpc" {
  source                  = "terraform-aws-modules/vpc/aws"
  version                 = "~> 5.0"
  name                    = var.vpc_name
  cidr                    = var.vpc_cidr
  azs                     = var.azs
  public_subnets          = var.public_subnets
  private_subnets         = var.private_subnets
  enable_dns_hostnames    = var.enable_dns_hostnames
  enable_dns_support      = var.enable_dns_support
  create_igw              = var.create_igw
  map_public_ip_on_launch = var.map_public_ip_on_launch
  enable_nat_gateway      = var.enable_nat_gateway
  single_nat_gateway      = var.single_nat_gateway
  one_nat_gateway_per_az  = var.one_nat_gateway_per_az
  tags                    = var.tags
}

# S3 Gateway VPC Endpoint for zero-cost, high-throughput internal routing
resource "aws_vpc_endpoint" "s3" {
  count           = var.enable_s3_endpoint ? 1 : 0
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${data.aws_region.current.name}.s3"
  route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags = merge(
    {
      Name = "${var.vpc_name}-s3-endpoint"
    },
    var.tags
  )
}