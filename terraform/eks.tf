module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets # nodes
  control_plane_subnet_ids = module.vpc.private_subnets # control-plane ENIs

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.enable_public_endpoint
  cluster_endpoint_public_access_cidrs = var.enable_public_endpoint ? var.admin_cidrs : null

  # Access Entries (modern) + aws-auth ConfigMap compatibility.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true
  
  access_entries = {
    teja = {
      principal_arn = "arn:aws:iam::706119322787:user/teja"
      type          = "STANDARD"

      policy_associations = {
        view_access = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # IRSA provider (used by the EBS CSI driver role below)
  enable_irsa = false

  cluster_addons = {
    # ---- ROOT-CAUSE FIX for the earlier failure --------------------------------
    # Nodes only become Ready once the CNI is running. If the node group is created
    # first, kubelet reports "NetworkPluginNotReady / cni plugin not initialized", the
    # node group never turns healthy and creation times out (NodeCreationFailure).
    # before_compute = true creates vpc-cni and kube-proxy BEFORE the node group.
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    kube-proxy = {
      most_recent    = true
      before_compute = true
    }
    # Needs nodes to schedule on, so it is created after the node group (default).
    coredns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    default = {
      name            = "${var.cluster_name}-ng"
      use_name_prefix = true

      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      # Node role gets AmazonEKSWorkerNodePolicy, AmazonEC2ContainerRegistryReadOnly and
      # AmazonEKS_CNI_Policy (iam_role_attach_cni_policy defaults to true). Missing CNI
      # policy is the other classic cause of an unhealthy node group.
      iam_role_attach_cni_policy = true
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # shell access without SSH/bastion
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2 # lets pods (hop 2) reach IMDS where needed
      }

      labels = { workload = "platform" }
    }
  }

  # Module creates and wires the cluster SG + node SG, including the required rules:
  #   cluster <-> nodes 443, nodes <-> nodes (all, covers kubelet 10250 / node-exporter 9100 /
  #   CoreDNS 53), control-plane -> nodes 10250 and webhook ports 4443/6443/8443/9443
  #   (needed by the Prometheus Operator admission webhook on 8443).
  # node_security_group_enable_recommended_rules defaults to true - do not turn it off.
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
