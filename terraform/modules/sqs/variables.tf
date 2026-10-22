variable "queue_name" {}
variable "delay_seconds" {}
variable "max_message_size" {}
variable "message_retention_seconds" {}
variable "visibility_timeout_seconds" {}
variable "receive_wait_time_seconds" {}
variable "maxReceiveCount" {}
variable "policy" {}
variable "tags" {
  type = map(string)
  default = {}  
}