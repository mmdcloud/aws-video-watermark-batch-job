variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "azs" {
  description = "Availability Zones for multi-AZ subnet deployment"
  type        = list(string)
}

variable "public_subnets" {
  description = "Public Subnet CIDR blocks"
  type        = list(string)
}

variable "private_subnets" {
  description = "Private Subnet CIDR blocks"
  type        = list(string)
}

variable "enable_dns_hostnames" {
  description = "Should be true to enable DNS hostnames in the VPC"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Should be true to enable DNS support in the VPC"
  type        = bool
  default     = true
}

variable "create_igw" {
  description = "Controls if an Internet Gateway is created for public subnets"
  type        = bool
  default     = true
}

variable "map_public_ip_on_launch" {
  description = "Should be false if you do not want to auto-assign public IPs on launch in public subnets"
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Should be true if you want to provision NAT Gateways for each of your private networks"
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Should be true if you want to provision a single shared NAT Gateway across all of your private networks"
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "Should be true if you want only one NAT Gateway per availability zone"
  type        = bool
  default     = false
}

variable "enable_s3_endpoint" {
  description = "Enable S3 Gateway VPC Endpoint for zero-cost high-throughput S3 access"
  type        = bool
  default     = true
}

variable "enable_dynamodb_endpoint" {
  description = "Enable DynamoDB Gateway VPC Endpoint for zero-cost private state table access"
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Enable VPC Interface Endpoints (PrivateLink) for ECR API, ECR DKR, and CloudWatch Logs"
  type        = bool
  default     = true
}

variable "enable_batch_endpoint" {
  description = "Enable AWS Batch Interface Endpoint (only needed if Lambda or internal compute is in VPC)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "A map of tags to add to all VPC resources"
  type        = map(string)
  default     = {}
}
