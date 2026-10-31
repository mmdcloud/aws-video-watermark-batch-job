output "arn" {
  value = aws_sqs_queue.queue.arn
}

output "name" {
  value = aws_sqs_queue.queue.name
}

output "url" {
  value = aws_sqs_queue.queue.url
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}


