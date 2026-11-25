output "name" {
  description = "The name of the CloudWatch metric alarm"
  value       = aws_cloudwatch_metric_alarm.alarm.alarm_name
}

output "arn" {
  description = "The ARN of the CloudWatch metric alarm"
  value       = aws_cloudwatch_metric_alarm.alarm.arn
}

output "id" {
  description = "The ID of the CloudWatch metric alarm"
  value       = aws_cloudwatch_metric_alarm.alarm.id
}
