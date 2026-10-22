# DynamoDB Table For storing media records
resource "aws_dynamodb_table" "mediaconvert-records" {
  name           = var.name
  billing_mode   = var.billing_mode
  read_capacity  = var.read_capacity
  write_capacity = var.write_capacity
  hash_key       = var.hash_key
  range_key      = var.range_key
  dynamic "attribute" {
    for_each = var.attributes
    content {
      name = attribute.value["name"]
      type = attribute.value["type"]
    }
  }

  ttl {
    attribute_name = var.ttl_attribute_name
    enabled        = var.ttl_attribute_enabled
  }

  tags = {
    Name = var.name
  }
}
