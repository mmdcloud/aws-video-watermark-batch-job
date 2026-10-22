output "id" {
  description = "ID of the security group"
  value       = aws_security_group.this.id
}

output "name" {
  description = "Name of the security group"
  value       = aws_security_group.this.name
}

output "arn" {
  description = "ARN of the security group"
  value       = aws_security_group.this.arn
}