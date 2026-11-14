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

# ------------------------------------------------------------------------------
# 1. Gateway VPC Endpoints ($0.00 / Free)
# ------------------------------------------------------------------------------

# S3 Gateway VPC Endpoint for zero-cost, high-throughput internal routing and ECR layer downloads
resource "aws_vpc_endpoint" "s3" {
  count           = var.enable_s3_endpoint ? 1 : 0
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${data.aws_region.current.region}.s3"
  route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags = merge(
    {
      Name = "${var.vpc_name}-s3-endpoint"
    },
    var.tags
  )
}

# DynamoDB Gateway VPC Endpoint for zero-cost private state table access
resource "aws_vpc_endpoint" "dynamodb" {
  count           = var.enable_dynamodb_endpoint ? 1 : 0
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags = merge(
    {
      Name = "${var.vpc_name}-dynamodb-endpoint"
    },
    var.tags
  )
}

# ------------------------------------------------------------------------------
# 2. Security Group for VPC Interface Endpoints
# ------------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  count       = var.enable_interface_endpoints || var.enable_batch_endpoint ? 1 : 0
  name        = "${var.vpc_name}-endpoints-sg"
  description = "Security group for VPC Interface Endpoints (ECR, CloudWatch Logs, Batch)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS inbound from VPC subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name = "${var.vpc_name}-endpoints-sg"
    },
    var.tags
  )
}

# ------------------------------------------------------------------------------
# 3. VPC Interface Endpoints (PrivateLink) for Batch Fargate Tasks in Private Subnets
# ------------------------------------------------------------------------------

# ECR API Interface Endpoint (Authentication & repository management)
resource "aws_vpc_endpoint" "ecr_api" {
  count               = var.enable_interface_endpoints ? 1 : 0
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
  tags = merge(
    {
      Name = "${var.vpc_name}-ecr-api-endpoint"
    },
    var.tags
  )
}

# ECR DKR Interface Endpoint (Docker image manifests & layer retrieval)
resource "aws_vpc_endpoint" "ecr_dkr" {
  count               = var.enable_interface_endpoints ? 1 : 0
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
  tags = merge(
    {
      Name = "${var.vpc_name}-ecr-dkr-endpoint"
    },
    var.tags
  )
}

# CloudWatch Logs Interface Endpoint (awslogs container log streaming)
resource "aws_vpc_endpoint" "logs" {
  count               = var.enable_interface_endpoints ? 1 : 0
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
  tags = merge(
    {
      Name = "${var.vpc_name}-logs-endpoint"
    },
    var.tags
  )
}

# AWS Batch Interface Endpoint (Optional: needed if orchestrator Lambda runs inside private subnets)
resource "aws_vpc_endpoint" "batch" {
  count               = var.enable_batch_endpoint ? 1 : 0
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.batch"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
  tags = merge(
    {
      Name = "${var.vpc_name}-batch-endpoint"
    },
    var.tags
  )
}
