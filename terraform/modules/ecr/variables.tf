variable "name" {
  description = "Name of the ECR repository"
  type        = string
}

variable "image_tag_mutability" {
  description = "The tag mutability setting for the repository (MUTABLE or IMMUTABLE)"
  type        = string
}

variable "force_delete" {
  description = "Whether to force delete the repository even if it contains images"
  type        = bool
  default     = true
}

variable "scan_on_push" {
  description = "Indicates whether images are scanned after being pushed to the repository"
  type        = bool
  default     = true
}

variable "enable_lifecycle_policy" {
  description = "Whether to attach a lifecycle policy to the ECR repository"
  type        = bool
  default     = true
}

variable "lifecycle_policy" {
  description = "Custom ECR lifecycle policy JSON document. If null or empty, a production default policy is applied."
  type        = string
  default     = null
}

variable "encryption_type" {
  description = "The encryption type to use for the repository (AES256 or KMS)"
  type        = string
  default     = null
}

variable "kms_key" {
  description = "The ARN of the KMS key to use when encryption_type is KMS"
  type        = string
  default     = null
}

variable "tags" {
  description = "A mapping of tags to assign to the ECR repository"
  type        = map(string)
  default     = {}
}
