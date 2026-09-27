# The 9 services on ECS Fargate (Spot), pulled straight from public GHCR images.
# Services find each other through Eureka; the Eureka server itself is found through a
# private DNS name (discovery-server.ecom.local) from Cloud Map.

resource "aws_ecs_cluster" "main" {
  name = local.name
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${local.name}.local"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "discovery_server" {
  name = "discovery-server"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# --- Permissions for ECS itself: pull, log, read the two secrets --------------------

resource "aws_iam_role" "execution" {
  name = "${local.name}-task-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameters"
      Resource = [aws_ssm_parameter.db_password.arn, aws_ssm_parameter.jwt_secret.arn]
    }]
  })
}

# --- One task definition + service per entry in local.services ----------------------

locals {
  db_env = {
    SPRING_PROFILES_ACTIVE     = "prod"
    SPRING_DATASOURCE_USERNAME = aws_db_instance.main.username
  }

  containers = {
    for name, svc in local.services : name => concat(
      # Creates this service's database if it does not exist yet, then exits.
      svc.db == "" ? [] : [{
        name      = "db-init"
        image     = "public.ecr.aws/docker/library/postgres:16-alpine"
        essential = false
        command = ["sh", "-c",
        "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB'\" | grep -q 1 || psql -c \"CREATE DATABASE $DB\""]
        environment = [
          { name = "PGHOST", value = aws_db_instance.main.address },
          { name = "PGUSER", value = aws_db_instance.main.username },
          { name = "PGDATABASE", value = "postgres" },
          { name = "PGSSLMODE", value = "require" },
          { name = "DB", value = svc.db },
        ]
        secrets = [{ name = "PGPASSWORD", valueFrom = aws_ssm_parameter.db_password.arn }]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.main.name
            awslogs-region        = var.region
            awslogs-stream-prefix = "${name}-db-init"
          }
        }
      }],
      [{
        name         = name
        image        = "ghcr.io/ar-ecommerce-backend/${name}:${var.image_tag}"
        essential    = true
        portMappings = [{ containerPort = svc.port }]
        dependsOn    = svc.db == "" ? [] : [{ containerName = "db-init", condition = "SUCCESS" }]
        environment = [
          for k, v in merge(
            {
              SERVER_PORT                          = tostring(svc.port)
              EUREKA_CLIENT_SERVICEURL_DEFAULTZONE = "http://discovery-server.${local.name}.local:8761/eureka/"
              JAVA_TOOL_OPTIONS                    = "-XX:MaxRAMPercentage=75"
              # Fargate tasks also have a link-local interface (169.254.172.x). Without this,
              # Spring registers that address in Eureka and nobody can reach the service.
              # "10.20." for the 10.20.0.0/16 VPC.
              SPRING_CLOUD_INETUTILS_PREFERREDNETWORKS = "${join(".", slice(split(".", aws_vpc.main.cidr_block), 0, 2))}."
            },
            svc.db == "" ? {} : merge(local.db_env, {
              SPRING_DATASOURCE_URL = "jdbc:postgresql://${aws_db_instance.main.address}:5432/${svc.db}"
            }),
            try(local.extra_env[name], {}),
          ) : { name = k, value = v }
        ]
        secrets = concat(
          svc.db == "" ? [] : [{ name = "SPRING_DATASOURCE_PASSWORD", valueFrom = aws_ssm_parameter.db_password.arn }],
          contains(local.jwt_services, name) ? [{ name = "JWT_SECRET", valueFrom = aws_ssm_parameter.jwt_secret.arn }] : [],
        )
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.main.name
            awslogs-region        = var.region
            awslogs-stream-prefix = name
          }
        }
      }],
    )
  }
}

resource "aws_ecs_task_definition" "svc" {
  for_each                 = local.services
  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions    = jsonencode(local.containers[each.key])
}

resource "aws_ecs_service" "svc" {
  for_each        = local.services
  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1

  # ponytail: Spot is ~70% cheaper and may be interrupted (ECS replaces the task).
  # Fine for demos; switch to FARGATE for anything people depend on.
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  dynamic "service_registries" {
    for_each = each.key == "discovery-server" ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.discovery_server.arn
    }
  }

  dynamic "load_balancer" {
    for_each = each.key == "api-gateway" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.gateway.arn
      container_name   = "api-gateway"
      container_port   = 8080
    }
  }

  # JVMs on 0.25 vCPU take a while to start and register with Eureka.
  health_check_grace_period_seconds = each.key == "api-gateway" ? 300 : null

  depends_on = [aws_ecs_cluster_capacity_providers.main, aws_lb_listener.http]
}

# --- Public entry point: load balancer -> gateway only -----------------------------

resource "aws_lb" "gateway" {
  name               = local.name
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "gateway" {
  name                 = "${local.name}-gateway"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 10
  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}
