variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "cluster_name" {
  type    = string
  default = "platform-dev-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Check `aws eks describe-addon-versions` / EKS docs for versions still in STANDARD support."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (your office/VPN egress IP, /32). Required - no 0.0.0.0/0 default."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Provide at least one specific admin CIDR and do not use 0.0.0.0/0."
  }
}

variable "enable_public_endpoint" {
  description = "false = API server reachable only from inside the VPC (needs VPN/bastion/SSM to run kubectl)."
  type        = bool
  default     = true
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7i-flex.large"] # 2 vCPU / 8 GiB; monitoring stack + Argo CD fit on 2 nodes
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  description = "true = one NAT (cheap, dev). false = one per AZ (HA)."
  type        = bool
  default     = true
}
