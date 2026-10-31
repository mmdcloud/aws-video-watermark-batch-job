# ECR repository for storing container images
resource "aws_ecr_repository" "repository" {
  name                 = var.name
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete
  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }
  tags = {
    Name = var.name
  }
}

resource "null_resource" "push_image_to_ecr" {
  triggers = var.triggers

  provisioner "local-exec" {
    command = var.bash_command
  }

  depends_on = [aws_ecr_repository.repository]
}