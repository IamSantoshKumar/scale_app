# main.tf
provider "aws" {
  region = var.region
}

# Attempt to look up existing VPC
data "aws_vpc" "existing" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Create VPC only if not found
resource "aws_vpc" "new" {
  count             = length(data.aws_vpc.existing.ids) > 0 ? 0 : 1
  cidr_block        = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = var.vpc_name
  }
}

locals {
  vpc_id = length(data.aws_vpc.existing.ids) > 0 ? data.aws_vpc.existing.ids[0] : aws_vpc.new[0].id
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.14"
  name    = var.vpc_name
  cidr    = var.vpc_cidr
  azs     = ["eu-north-1a", "eu-north-1b", "eu-north-1c"]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true

  tags = {
    Name = var.vpc_name
  }
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.27"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  enable_irsa     = true

  node_groups = {
    default = {
      desired_capacity = 1
      max_capacity     = 2
      min_capacity     = 1

      instance_types = ["t3.micro"]
    }
  }
}

# Try to reuse existing ECR repository
data "aws_ecr_repository" "existing" {
  name = var.ecr_repo_name
  count = 1
}

resource "aws_ecr_repository" "new" {
  count = length(data.aws_ecr_repository.existing) > 0 ? 0 : 1
  name  = var.ecr_repo_name
}

output "ecr_repo_url" {
  value = length(data.aws_ecr_repository.existing) > 0 ? data.aws_ecr_repository.existing[0].repository_url : aws_ecr_repository.new[0].repository_url
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

# Kubernetes provider
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = module.eks.cluster_token
}

resource "kubernetes_deployment" "flask" {
  metadata {
    name = "flask-app"
    labels = {
      app = "flask"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "flask"
      }
    }

    template {
      metadata {
        labels = {
          app = "flask"
        }
      }

      spec {
        container {
          image = "${length(data.aws_ecr_repository.existing) > 0 ? data.aws_ecr_repository.existing[0].repository_url : aws_ecr_repository.new[0].repository_url}:latest"
          name  = "flask"

          port {
            container_port = 5000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "flask_lb" {
  metadata {
    name = "flask-lb"
  }
  spec {
    selector = {
      app = "flask"
    }

    type = "LoadBalancer"

    port {
      port        = 80
      target_port = 5000
    }
  }
}

output "flask_service_url" {
  value = kubernetes_service.flask_lb.status[0].load_balancer[0].ingress[0].hostname
}
