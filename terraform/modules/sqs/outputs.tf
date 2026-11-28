output "arn" {
  value = aws_sqs_queue.queue.arn
}

output "name" {
  value = aws_sqs_queue.queue.name
}

output "url" {
  value = aws_sqs_queue.queue.url
}

output "id" {
  value = aws_sqs_queue.queue.id
}

output "fifo_queue" {
  value = aws_sqs_queue.queue.fifo_queue
}

output "policy_id" {
  value = try(aws_sqs_queue_policy.queue_policy[0].id, null)
}

output "redrive_allow_policy_id" {
  value = try(aws_sqs_queue_redrive_allow_policy.redrive_allow[0].id, null)
}
