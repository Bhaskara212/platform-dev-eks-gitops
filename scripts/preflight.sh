#!/usr/bin/env bash
# Run BEFORE terraform apply. Does not assume the cluster exists.
set -uo pipefail
REGION=${REGION:-ap-southeast-2}; CLUSTER=${CLUSTER:-platform-dev-eks}
ok(){ echo "  [ok]   $*"; }; bad(){ echo "  [FAIL] $*"; FAIL=1; }; FAIL=0

echo "== tools"
for t in aws terraform kubectl helm jq; do command -v $t >/dev/null && ok $t || bad "missing $t"; done

echo "== identity / region"
aws sts get-caller-identity --query Arn --output text || bad "AWS credentials not working"
echo "  region=$REGION"

echo "== leftovers from the earlier failed attempt"
if aws eks describe-cluster --region $REGION --name $CLUSTER --query 'cluster.[status,version]' --output text 2>/dev/null; then
  echo "  cluster exists -> run scripts/diagnose.sh; do NOT blindly re-apply"
  aws eks list-nodegroups --region $REGION --cluster-name $CLUSTER --output text
else
  ok "no cluster named $CLUSTER (clean slate)"
fi
echo "  VPCs tagged for this cluster:"
aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=$CLUSTER" \
  --query 'Vpcs[].[VpcId,CidrBlock]' --output text
echo "  Orphan ENIs/NAT/EIPs (cost + subnet IP exhaustion):"
aws ec2 describe-nat-gateways --region $REGION --filter "Name=state,Values=available,pending,failed" \
  --query 'NatGateways[].[NatGatewayId,State,VpcId]' --output text
aws ec2 describe-addresses --region $REGION --query 'Addresses[?AssociationId==`null`].[AllocationId,PublicIp]' --output text

echo "== quotas (ap-southeast-2)"
aws service-quotas get-service-quota --region $REGION --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text 2>/dev/null | sed 's/^/  Running On-Demand Standard vCPUs: /'
aws service-quotas get-service-quota --region $REGION --service-code ec2 --quota-code L-0263D0A3 \
  --query 'Quota.Value' --output text 2>/dev/null | sed 's/^/  Elastic IPs: /'
aws service-quotas get-service-quota --region $REGION --service-code vpc --quota-code L-FE5A380F \
  --query 'Quota.Value' --output text 2>/dev/null | sed 's/^/  NAT gateways per AZ: /'

[ $FAIL -eq 0 ] && echo "preflight OK" || { echo "preflight FAILED"; exit 1; }
