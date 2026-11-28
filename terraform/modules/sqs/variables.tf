variable "queue_name" {
  type        = string
  description = "Name of the SQS queue (must end with '.fifo' when fifo_queue = true)"
}

variable "fifo_queue" {
  type        = bool
  default     = false
  nullable    = false
  description = "Boolean designating a FIFO queue. Changing this forces recreation of the queue."
}

variable "content_based_deduplication" {
  type        = bool
  default     = false
  nullable    = false
  description = "Enables content-based deduplication for FIFO queues (only valid when fifo_queue = true)"
}

variable "deduplication_scope" {
  type        = string
  default     = null
  description = "Specifies whether message deduplication occurs at the message group or queue level ('messageGroup' or 'queue'; FIFO only)"

  validation {
    condition     = var.deduplication_scope == null ? true : contains(["messageGroup", "queue"], var.deduplication_scope)
    error_message = "deduplication_scope must be null, 'messageGroup', or 'queue'."
  }
}

variable "fifo_throughput_limit" {
  type        = string
  default     = null
  description = "Specifies whether the FIFO queue throughput quota applies to the entire queue or per message group ('perQueue' or 'perMessageGroupId'; FIFO only)"

  validation {
    condition     = var.fifo_throughput_limit == null ? true : contains(["perQueue", "perMessageGroupId"], var.fifo_throughput_limit)
    error_message = "fifo_throughput_limit must be null, 'perQueue', or 'perMessageGroupId'."
  }
}

variable "delay_seconds" {
  type        = number
  default     = 0
  description = "The time in seconds that the delivery of all messages in the queue will be delayed"
}

variable "max_message_size" {
  type        = number
  default     = 262144
  description = "The limit of how many bytes a message can contain"
}

variable "message_retention_seconds" {
  type        = number
  default     = 345600
  description = "The number of seconds Amazon SQS retains a message"
}

variable "visibility_timeout_seconds" {
  type        = number
  default     = 180
  description = "The visibility timeout for the queue in seconds"
}

variable "receive_wait_time_seconds" {
  type        = number
  default     = 20
  description = "The time for which a ReceiveMessage call will wait for a message to arrive"
}

variable "policy" {
  type        = string
  default     = null
  description = "Optional custom JSON policy document for the SQS queue (merged with enforce_tls and queue_policy_statements)"
}

variable "enforce_tls" {
  type        = bool
  default     = true
  nullable    = false
  description = "Whether to attach a statement denying non-HTTPS (aws:SecureTransport = false) requests to this queue"
}

variable "queue_policy_statements" {
  type = map(object({
    sid       = optional(string)
    effect    = optional(string, "Allow")
    actions   = list(string)
    resources = optional(list(string))
    principals = optional(list(object({
      type        = string
      identifiers = list(string)
    })), [])
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default     = {}
  nullable    = false
  description = "Map of generic IAM policy statements for the SQS queue. If resources is omitted, defaults to this queue's ARN."
}

variable "redrive_policy" {
  type        = string
  default     = null
  description = "The JSON policy for the SQS redrive policy"
}

variable "redrive_allow_policy" {
  type        = string
  default     = null
  description = "Optional raw JSON policy for the SQS redrive allow policy"
}

variable "redrive_permission" {
  type        = string
  default     = null
  description = "Redrive permission type when configuring redrive allow policy ('allowAll', 'denyAll', or 'byQueue')"

  validation {
    condition     = var.redrive_permission == null ? true : contains(["allowAll", "denyAll", "byQueue"], var.redrive_permission)
    error_message = "redrive_permission must be one of 'allowAll', 'denyAll', or 'byQueue'."
  }
}

variable "redrive_allow_source_queue_arns" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "List of source queue ARNs permitted to use this queue as a DLQ when redrive_permission is 'byQueue'"
}

variable "redrive_allow_source_queue_names" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "List of source queue names in the current account/region permitted to use this queue as a DLQ when redrive_permission is 'byQueue'"
}

variable "sqs_managed_sse_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "Boolean to enable server-side encryption (SSE) of message content with SQS-owned encryption keys"
}

variable "kms_master_key_id" {
  type        = string
  default     = null
  description = "The ID of an AWS-managed customer master key (CMK) for Amazon SQS or a custom CMK"
}

variable "kms_data_key_reuse_period_seconds" {
  type        = number
  default     = null
  description = "The length of time (60-86400 seconds) Amazon SQS can reuse a data key to encrypt/decrypt messages before calling AWS KMS again"

  validation {
    condition     = var.kms_data_key_reuse_period_seconds == null ? true : (var.kms_data_key_reuse_period_seconds >= 60 && var.kms_data_key_reuse_period_seconds <= 86400)
    error_message = "kms_data_key_reuse_period_seconds must be between 60 and 86400 seconds."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Additional tags to apply to the SQS queue"
}
