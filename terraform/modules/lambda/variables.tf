variable "function_name" {
  type = string
}
variable "role_arn" {}
variable "handler" {}
variable "runtime" {}
variable "s3_bucket" {}
variable "s3_key" {}
variable "code_signing_config_arn" {
  type = string
  default = null
}
variable "layers" {
  type = list(string)
}
variable "env_variables" {
  type = map(string)
}
variable "permissions" {
  type = list(object({
    statement_id = string
    action       = string
    principal    = string
    source_arn   = string
  }))
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "vpc_config" {
  type = object({
    security_group_ids = set(string)
    subnet_ids         = set(string)
  })
    default = null  # ADD THIS

}
variable "dead_letter_config" {
  type = object({
    target_arn = string
  })
  default = null 
}
variable "source_code_hash" {
  type    = string
  default = null
}
