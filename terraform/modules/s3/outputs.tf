output "bucket" {
  value = aws_s3_bucket.bucket.bucket
}
output "arn" {
  value = aws_s3_bucket.bucket.arn
}
output "objects" {
  value = aws_s3_object.object[*]
}
