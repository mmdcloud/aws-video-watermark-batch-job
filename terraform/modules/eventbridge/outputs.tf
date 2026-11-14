output "rule_name" {
  description = "Name of the EventBridge rule"
  value       = try(aws_cloudwatch_event_rule.this[0].name, null)
}

output "rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = try(aws_cloudwatch_event_rule.this[0].arn, null)
}

output "rule_id" {
  description = "ID of the EventBridge rule"
  value       = try(aws_cloudwatch_event_rule.this[0].id, null)
}

output "event_bus_name" {
  description = "Name of the EventBridge event bus"
  value       = var.create_event_bus ? aws_cloudwatch_event_bus.this[0].name : var.event_bus_name
}

output "event_bus_arn" {
  description = "ARN of the EventBridge event bus if created by this module"
  value       = try(aws_cloudwatch_event_bus.this[0].arn, null)
}

output "target_ids" {
  description = "Map of target keys to their target IDs"
  value       = { for k, v in aws_cloudwatch_event_target.this : k => v.target_id }
}

output "target_arns" {
  description = "Map of target keys to their target ARNs"
  value       = { for k, v in aws_cloudwatch_event_target.this : k => v.arn }
}
