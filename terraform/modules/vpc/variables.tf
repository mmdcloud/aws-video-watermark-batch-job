variable "vpc_name" {}
variable "vpc_cidr" {}
variable "azs" {}
variable "public_subnets" {}
variable "private_subnets" {}
variable "enable_dns_hostnames" {}
variable "enable_dns_support" {}
variable "create_igw" {}
variable "map_public_ip_on_launch" {}
variable "enable_nat_gateway" {}
variable "single_nat_gateway" {}
variable "one_nat_gateway_per_az" {}
variable "enable_s3_endpoint" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}