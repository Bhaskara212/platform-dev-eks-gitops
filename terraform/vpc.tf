data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # 10.20.0.0/16 ->
  #   private (nodes + pods): 10.20.0.0/20, 10.20.16.0/20, 10.20.32.0/20   (4091 usable IPs each)
  #   public  (NAT + future public LBs): 10.20.200.0/24, .201.0/24, .202.0/24
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 200 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Nodes in private subnets need egress to: EKS API, ECR, S3, STS, EC2, GitHub (Argo), quay.io/registry.k8s.io (images).
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # REQUIRED for EKS: nodes resolve the cluster endpoint and AWS service names.
  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Free gateway endpoint: keeps ECR image-layer pulls (S3) off the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}
