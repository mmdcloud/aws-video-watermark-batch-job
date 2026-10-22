variable "name" {}
variable "billing_mode" {}
variable "read_capacity" {
  type = number
  default = null
}
variable "write_capacity" {
  type = number
  default = null
}
variable "hash_key" {}
variable "range_key" {}
variable "attributes" {
  type = list(object({
    name = string
    type = string
  }))
}
variable "ttl_attribute_name" {}
variable "ttl_attribute_enabled" {}