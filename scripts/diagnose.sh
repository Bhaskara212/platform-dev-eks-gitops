#!/usr/bin/env bash
# Triage for "VPC CNI addon / node group unhealthy". Read-only.
set -uo pipefail
REGION=${REGION:-ap-southeast-2}; CLUSTER=${CLUSTER:-platform-dev-eks}

echo "== cluster"; aws eks describe-cluster --region $REGION --name $CLUSTER \
  --query 'cluster.{status:status,version:version,endpoint:endpoint,private:resourcesVpcConfig.endpointPrivateAccess,public:resourcesVpcConfig.endpointPublicAccess,subnets:resourcesVpcConfig.subnetIds}'

echo "== addons"
for a in $(aws eks list-addons --region $REGION --cluster-name $CLUSTER --query 'addons[]' --output text); do
  echo "-- $a"; aws eks describe-addon --region $REGION --cluster-name $CLUSTER --addon-name $a \
    --query 'addon.{status:status,version:addonVersion,issues:health.issues}'
done

echo "== node groups"
for ng in $(aws eks list-nodegroups --region $REGION --cluster-name $CLUSTER --query 'nodegroups[]' --output text); do
  echo "-- $ng"; aws eks describe-nodegroup --region $REGION --cluster-name $CLUSTER --nodegroup-name $ng \
    --query 'nodegroup.{status:status,issues:health.issues,role:nodeRole,subnets:subnets,scaling:scalingConfig}'
done

echo "== in-cluster (needs working kubeconfig)"
kubectl get nodes -o wide 2>&1 | head -20
kubectl -n kube-system get ds aws-node kube-proxy 2>&1
kubectl -n kube-system logs ds/aws-node -c aws-node --tail=30 2>&1 | head -40
