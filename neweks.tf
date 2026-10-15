terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------
# Variables - the ONLY place the Kubernetes version is set.
# Must always match the version the cluster is actually running:
#   aws eks describe-cluster --name my-cluster --query cluster.version
# Upgrade one minor version at a time (1.31 -> 1.32 -> 1.33).
# Never set this lower than the live version: EKS can't downgrade.
# ---------------------------------------------------------------
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "cluster_name" {
  type    = string
  default = "my-cluster"
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

data "aws_availability_zones" "available" {}

# 1. Create a VPC with public IP assignment enabled for lab nodes
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# 2. Create the EKS Cluster with worker nodes in public subnets
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.public_subnets
  cluster_endpoint_public_access = true

  enable_irsa = true

  # FIX: module v20 defaults this to false, so the IAM identity running
  # Terraform (vivekadmin) gets no access to the cluster and the Helm
  # release fails with "Unauthorized". This adds an EKS access entry
  # with cluster-admin for whoever runs terraform apply.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    my-nodes = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["c7i-flex.large"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 20
            volume_type = "gp3"
          }
        }
      }

      key_name = "mumbai"
    }
  }
}

# 3. Configure Helm Provider with explicit region authentication
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
      command     = "aws"
    }
  }
}

# 4. IAM Role for the AWS Load Balancer Controller
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# 5. Buffer to allow EKS API server authentication webhook to initialize fully
resource "null_resource" "wait_for_eks" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "sleep 30"
  }
}

# 6. Deploy the AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.0" # pinned so a new chart release can't sneak in
  namespace  = "kube-system"

  depends_on = [
    null_resource.wait_for_eks,
    module.load_balancer_controller_irsa_role,
  ]

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  # Pass region + VPC explicitly so the controller doesn't depend on
  # the node's instance metadata (IMDS) to discover them.
  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.load_balancer_controller_irsa_role.iam_role_arn
  }
}
