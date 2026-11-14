variable "create_rule" {
  description = "Whether to create the EventBridge rule resource"
  type        = bool
  default     = true
}

variable "name" {
  description = "The name of the EventBridge rule"
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "The prefix for the name of the EventBridge rule (conflicts with name)"
  type        = string
  default     = null
}

variable "description" {
  description = "The description of the EventBridge rule"
  type        = string
  default     = null
}

variable "event_bus_name" {
  description = "The name or ARN of the event bus to associate with this rule"
  type        = string
  default     = "default"
}

variable "create_event_bus" {
  description = "Whether to create a custom EventBridge event bus with the given event_bus_name"
  type        = bool
  default     = false
}

variable "event_pattern" {
  description = "The event pattern described as a JSON object string"
  type        = string
  default     = null
}

variable "schedule_expression" {
  description = "The scheduling expression (e.g., cron(...) or rate(...))"
  type        = string
  default     = null
}

variable "state" {
  description = "State of the rule (ENABLED or DISABLED)"
  type        = string
  default     = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.state)
    error_message = "Valid values for state are 'ENABLED' or 'DISABLED'."
  }
}

variable "role_arn" {
  description = "The Amazon Resource Name (ARN) of the IAM role associated with the rule"
  type        = string
  default     = null
}

variable "targets" {
  description = "Map of target configurations to associate with the EventBridge rule"
  type = map(object({
    arn                      = string
    target_id                = optional(string)
    role_arn                 = optional(string)
    input                    = optional(string)
    input_path               = optional(string)
    statement_id             = optional(string)
    attach_lambda_permission = optional(bool, false)
    lambda_function_name     = optional(string)
    input_transformer = optional(object({
      input_paths    = optional(map(string))
      input_template = string
    }))
    retry_policy = optional(object({
      maximum_event_age_in_seconds = optional(number)
      maximum_retry_attempts       = optional(number)
    }))
    dead_letter_config = optional(object({
      arn = optional(string)
    }))
  }))
  default = {}
}

variable "tags" {
  description = "A mapping of tags to assign to the EventBridge resources"
  type        = map(string)
  default     = {}
}
