variable "dimensions" {}
variable "alarm_name" {}
variable "comparison_operator" {}
variable "evaluation_periods" {}
variable "metric_name" {}
variable "namespace" {}
variable "period" {}
variable "statistic" {
  default = ""
}
variable "threshold" {}
variable "alarm_description" {}
variable "alarm_actions" {}
variable "ok_actions" {
  type    = set(string)
  default = []
}
variable "extended_statistic" {
  default = ""
}
