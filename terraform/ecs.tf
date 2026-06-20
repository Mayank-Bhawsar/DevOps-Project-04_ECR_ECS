resource "aws_cloudwatch_log_group" "ecs_logs" {
    name = "/ecs/django-app"
    retention_in_days = 7
    tags= {
        Environment = "production"
    }
  
}

resource "aws_ecs_cluster" "main" {
  name = "django-production-cluster"
}

resource "aws_security_group" "ecs_tasks" {
  name = "devops-04-ecs-tasks-sg"
  description = "Allow inbound traffic from ALG only"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port = 8000
    to_port = 8000
    protocol = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devops-04-ecs-tasks-sg"
  }
}

resource "aws_ecs_task_definition" "app" {
  family = "django-app-task"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = "256"
  memory = "512"
  execution_role_arn = aws_iam_role.ecs_execution_role.arn
  task_role_arn = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name = "django-app"
    image = "${aws_ecr_repository.django_app.repository_url}:latest"
    essential = true
    portMappings = [{
        containerPort = 8000
        hostPort = 8000
    }]

    secrets = [
        {
            name = "DJANGO_SECRET_KEY"
            valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:DJANGO_SECRET_KEY::"
        }
    ]


    logConfiguration = {
        logDriver = "awslogs"
        options = {
            "awslogs-group" = aws_cloudwatch_log_group.ecs_logs.name
            "awslogs-region" = "ap-south-1"
            "awslogs-stream-prefix" = "django"
        }
    }
  }])
}

resource "aws_ecs_service" "main" {
  name = "django-production-service"
  cluster = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count = 2
  launch_type = "FARGATE"

  network_configuration {
    subnets = aws_subnet.private.*.id
    security_groups = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false

  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app.arn
    container_name = "django-app"
    container_port = 8000
  }
  lifecycle {
    ignore_changes = [ desired_count, task_definition ]
  }
  depends_on = [ aws_alb_listener.http ]
}

