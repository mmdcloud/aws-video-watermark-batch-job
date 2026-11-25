variable "alarm_name" {
  description = "The descriptive name for the alarm"
  type        = string
}

variable "comparison_operator" {
  description = "The arithmetic operation to use when comparing the specified Statistic and Threshold"
  type        = string
}

variable "evaluation_periods" {
  description = "The number of periods over which data is compared to the specified threshold"
  type        = number
}

variable "metric_name" {
  description = "The name for the alarm's associated metric"
  type        = string
}

variable "namespace" {
  description = "The namespace for the alarm's associated metric"
  type        = string
}

variable "period" {
  description = "The period in seconds over which the specified statistic is applied"
  type        = number
}

variable "statistic" {
  description = "The statistic to apply to the alarm's associated metric"
  type        = string
  default     = null
}

variable "extended_statistic" {
  description = "The percentile statistic for the metric associated with the alarm"
  type        = string
  default     = null
}

variable "threshold" {
  description = "The value against which the specified statistic is compared"
  type        = number
}

variable "alarm_description" {
  description = "The description for the alarm"
  type        = string
  default     = null
}

variable "alarm_actions" {
  description = "The list of actions to execute when this alarm transitions into an ALARM state"
  type        = list(string)
  default     = []
}

variable "ok_actions" {
  description = "The list of actions to execute when this alarm transitions into an OK state"
  type        = list(string)
  default     = []
}

variable "dimensions" {
  description = "The dimensions for the alarm's associated metric"
  type        = map(string)
  default     = {}
}

variable "treat_missing_data" {
  description = "Sets how this alarm is to handle missing data points"
  type        = string
  default     = "missing"
}

variable "tags" {
  description = "A mapping of tags to assign to the resource"
  type        = map(string)
  default     = {}
}
