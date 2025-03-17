#---------------------------
# ECS CloudWatch Log Group
#---------------------------
resource "aws_cloudwatch_log_group" "ecs_vault" {
  name = "ecs/vault"

  retention_in_days = var.ecs_logs_retention_days

  tags = {
    Name = "vault"
  }
}

#---------------------------
# ECR Repository
#---------------------------

resource "aws_ecr_repository" "vault_ecr" {
  name                 = var.ecr_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }
}

#---------------------------
# ECS Cluster
#---------------------------
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster
resource "aws_ecs_cluster" "ecs_cluster" {
  name = var.ecs_cluster_name
}

resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity" {
  cluster_name = aws_ecs_cluster.ecs_cluster.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

#---------------------------
# ECS Task Definition
#---------------------------
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition

resource "aws_ecs_task_definition" "ecs_task_def" {
  count                    = 2
  family                   = "vault-ecs-task-def-${count.index}"
  execution_role_arn       = aws_iam_role.ecs_vault_task_exec_role.arn
  task_role_arn            = aws_iam_role.ecs_vault_task_role.arn
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  #comment VAULT_SEAL_TYPE if vault data migration is needed
  container_definitions = <<TASK_DEFINITION
[
  {
    "name": "vault-docker",
    "image": "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/vault:${var.vault_version}",
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${aws_cloudwatch_log_group.ecs_vault.id}",
        "awslogs-region": "${var.aws_region}",
        "awslogs-stream-prefix": "${var.ecs_service_name}"
      }
    },
    "portMappings": [
      {
        "name": "vault-${count.index}-8200",
        "hostPort": 8200,
        "protocol": "tcp",
        "containerPort": 8200
      },
      {
        "name": "vault-${count.index}-8201",
        "hostPort": 8201,
        "protocol": "tcp",
        "containerPort": 8201
      }
    ],
    "environment": [
      {
          "name": "VAULT_ADDR",
          "value": "http://0.0.0.0:8200"
      },
      {
          "name": "VAULT_API_ADDR",
          "value": "http://vault-${count.index}.${aws_service_discovery_private_dns_namespace.vault.name}:8200"
      },
      {
        "name": "VAULT_CLUSTER_ADDR",
        "value": "http://vault-${count.index}.${aws_service_discovery_private_dns_namespace.vault.name}:8201"
      },
      {
        "name": "AWS_REGION",
        "value": "${var.aws_region}"
      },
      {
        "name": "VAULT_DISABLE_MLOCK",
        "value": "false"
      },
      {
        "name": "VAULT_LOG_LEVEL",
        "value": "${var.vault_log_level}"
      }
    ],
    "essential": true
  }
]
TASK_DEFINITION

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

resource "aws_service_discovery_private_dns_namespace" "vault" {
  name        = "vault.private"
  description = "Vault private DNS namespace"
  vpc         = module.vpc.vpc_id
}

resource "aws_service_discovery_service" "vault" {
  count = 2
  name  = format("%s-%s", var.ecs_service_name, count.index) #vault-0 or vault-1

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.vault.id # vault-0.vault.private or vault-1.vault.private 

    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

#---------------------------
# ECS Service
#---------------------------

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service
resource "aws_ecs_service" "vault_svc" {
  count                  = 2
  name                   = "${var.ecs_service_name}-${count.index}"
  cluster                = aws_ecs_cluster.ecs_cluster.arn
  task_definition        = aws_ecs_task_definition.ecs_task_def[count.index].arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets = module.vpc.private_subnets
    security_groups = [
      aws_security_group.vault.id
    ]
    assign_public_ip = "false"
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.vault.arn
    service {
      client_alias {
        dns_name = "vault-${count.index}" #vault-0 or vault-1
        port     = 8200
      }
      port_name = "vault-${count.index}-8200"
    }

    service {
      client_alias {
        dns_name = "vault-${count.index}" #vault-0 or vault-1
        port     = 8201
      }
      port_name = "vault-${count.index}-8201"
    }

  }

  service_registries {
    registry_arn = aws_service_discovery_service.vault[count.index].arn
  }

}

