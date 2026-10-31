variable "name" {
  type = string
}
variable "image_tag_mutability" {
  type = string
}
variable "force_delete" {
  type = bool
}
variable "scan_on_push" {
  type = bool
}
variable "bash_command" {
  type = string
}
variable "triggers" {
  type    = map(string)
  default = {}
}
