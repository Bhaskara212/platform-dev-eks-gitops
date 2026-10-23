region          = "ap-southeast-2"
cluster_name    = "platform-dev-eks"
cluster_version = "1.36"
vpc_cidr        = "10.20.0.0/16"

# Your egress IP(s) - find with: curl -s https://checkip.amazonaws.com
admin_cidrs = ["35.177.238.18/32"]

# Set false to make the API server VPC-only (then use VPN / SSM-bastion for kubectl)
enable_public_endpoint = true
