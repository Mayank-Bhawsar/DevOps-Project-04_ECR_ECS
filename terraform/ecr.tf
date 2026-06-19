resource "aws_ecr_repository" "django_app" {
  name = "django-app-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "devops-project-04"
  }
}