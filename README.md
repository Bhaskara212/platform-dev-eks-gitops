# platform-dev-eks — EKS + Argo CD + Prometheus/Grafana/Alertmanager (dev/PoC)

Region `ap-southeast-2` · cluster `platform-dev-eks` · Terraform for infra · Argo CD GitOps for everything in-cluster · internal-only (ClusterIP + `kubectl port-forward`).

```
.
├── terraform/                  # VPC, EKS, add-ons, node group, EBS CSI IRSA
├── gitops/
│   ├── bootstrap/              # applied by hand once: argocd-values.yaml, root-app.yaml
│   ├── apps/                   # Argo CD Applications (app-of-apps children, sync-waved)
│   └── platform/
│       ├── storage/            # gp3 default StorageClass
│       ├── monitoring/values.yaml   # kube-prometheus-stack values
│       └── monitoring-extras/  # custom PrometheusRule
└── scripts/                    # preflight.sh, diagnose.sh, validate.sh
```

## 0. Network & security design (what EKS needs)

| Item | Value | Why |
|---|---|---|
| VPC CIDR | `10.20.0.0/16` | Must not overlap your VPN/on-prem/other VPCs (pick another if it does). Cannot be changed later. |
| AZs | 3 × (`ap-southeast-2a/b/c`) | EKS needs ≥2 AZs; 3 gives spread for EBS/pods. |
| Private subnets | `10.20.0.0/20`, `10.20.16.0/20`, `10.20.32.0/20` | Nodes **and pods** (VPC CNI gives each pod a VPC IP, so size generously). Tag `kubernetes.io/role/internal-elb=1`. |
| Public subnets | `10.20.200.0/24`, `.201.0/24`, `.202.0/24` | NAT gateway only (+ future public LBs). Tag `kubernetes.io/role/elb=1`. |
| Internet egress | 1 NAT GW (dev; set `single_nat_gateway=false` for HA) | Nodes pull images (quay.io, registry.k8s.io, ghcr.io, ECR), Argo CD reaches Git, nodes reach EKS/STS/EC2 APIs. **No egress = nodes never join = the "unhealthy node group" symptom.** |
| DNS | `enable_dns_support` + `enable_dns_hostnames` = true | Required for nodes to resolve the private EKS endpoint. |
| S3 gateway endpoint | yes (free) | ECR layers come from S3, bypasses NAT. |
| API endpoint | private **on**, public **on** restricted to `admin_cidrs` | Lets you run `kubectl`/port-forward from your laptop. Set `enable_public_endpoint=false` for strict private-only (needs VPN/SSM bastion in the VPC). |

**Security groups** (created and wired by the EKS module — don't hand-roll them):

| SG | Rule | Purpose |
|---|---|---|
| Cluster SG (EKS-managed) | nodes → 443 | kubelet/CNI/kube-proxy talk to API server |
| Node SG | ingress 443 / 10250 / 4443 / 6443 / 8443 / 9443 **from cluster SG** | control plane → kubelet and admission webhooks (Prometheus Operator webhook uses 8443) |
| Node SG | ingress all **from itself** | pod↔pod, CoreDNS 53, Prometheus → node-exporter 9100 / kubelet 10250 |
| Node SG | egress all | image pulls, AWS APIs |

**IAM**: cluster role (`AmazonEKSClusterPolicy`), node role (`AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, **`AmazonEKS_CNI_Policy`**, SSM core), EBS CSI IRSA role (`AmazonEBSCSIDriverPolicy`), OIDC provider for IRSA.

### Why the earlier VPC CNI / node-group failure is addressed
Typical causes, and where each is handled:
1. Node group created before the CNI exists → nodes stay `NotReady` ("cni plugin not initialized") → `vpc-cni` + `kube-proxy` use **`before_compute = true`** (`eks.tf`).
2. Node role missing `AmazonEKS_CNI_Policy` → `iam_role_attach_cni_policy = true`.
3. No route out (no NAT/endpoints) → NAT + DNS flags in `vpc.tf`.
4. Subnets too small / IPs exhausted → /20 private subnets.
5. Leftover half-created cluster/node group/addon from the failed run → step 2 below. A node group in `CREATE_FAILED` or `DEGRADED` can't be repaired in place.

## 1. Prerequisites
- AWS CLI v2, Terraform ≥ 1.5.7, kubectl, Helm 3, jq. Credentials with admin-ish rights on the account.
- A Git repo (this directory pushed to it), e.g. `https://github.com/YOUR_ORG/platform-dev-eks-gitops.git`. If private: a read-only deploy key or token.
- EC2 quotas OK for 2–3 × t3.large (+1 EIP for NAT).
- Optional but recommended: S3 + DynamoDB backend (`terraform/backend.tf.example`).

```bash
cd platform-dev-eks-gitops
./scripts/preflight.sh          # tool check, leftovers, quotas
```

## 2. Clean up the previous failed attempt (skip if preflight says clean slate)
```bash
./scripts/diagnose.sh                          # shows addon/nodegroup health issues + aws-node logs
cd terraform && terraform init
terraform state list | head                    # is anything tracked?
terraform destroy -var-file=terraform.tfvars   # preferred: clean, state-driven teardown
# If the cluster exists but is NOT in state (orphan):
#   aws eks delete-nodegroup --region ap-southeast-2 --cluster-name platform-dev-eks --nodegroup-name <ng>
#   aws eks delete-addon     --region ap-southeast-2 --cluster-name platform-dev-eks --addon-name vpc-cni
#   aws eks delete-cluster   --region ap-southeast-2 --name platform-dev-eks
# then remove orphaned NAT GW / EIPs / ENIs / VPC listed by preflight.
```

## 3. Create the cluster (Terraform)
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars     # set admin_cidrs = ["<your-ip>/32"]
terraform init
terraform fmt -recursive && terraform validate
terraform plan -out tfplan
terraform apply tfplan                            # ~15-20 min
$(terraform output -raw kubeconfig_command)
kubectl get nodes -o wide                         # expect 2 x Ready
kubectl -n kube-system get ds aws-node kube-proxy
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl get sc                                    # gp2 exists; gp3 comes from Argo CD later
```
Gate: do not continue until both nodes are `Ready` and `aws-node` is `2/2 READY`. If not: `./scripts/diagnose.sh`.

> EKS version: `cluster_version` defaults to 1.36. Confirm it is still in **standard** support (extended support costs extra): `aws eks describe-cluster-versions --region ap-southeast-2` / EKS docs.

## 4. Point manifests at your Git repo
```bash
REPO=https://github.com/YOUR_ORG/platform-dev-eks-gitops.git     # <-- your real URL
grep -rl YOUR_ORG gitops | xargs sed -i "s#https://github.com/YOUR_ORG/platform-dev-eks-gitops.git#${REPO}#g"
git add -A && git commit -m "Set repo URL" && git push origin main
```

## 5. Install Argo CD (one-time bootstrap)
```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm search repo argo/argo-cd --versions | head -3        # pick a version and pin it below
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version <PINNED_VERSION> \
  -f gitops/bootstrap/argocd-values.yaml --wait --timeout 10m

# Private repo only (credentials live in the cluster, never in Git):
kubectl -n argocd create secret generic repo-platform \
  --from-literal=type=git --from-literal=url="$REPO" \
  --from-literal=username=<user> --from-literal=password=<read-only-token>
kubectl -n argocd label secret repo-platform argocd.argoproj.io/secret-type=repository
```

## 6. Pre-create the Grafana admin secret (not stored in Git)
```bash
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo   # save it
```

## 7. Hand over to GitOps
```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
kubectl -n argocd get applications -w
```
Sync order (sync-waves): `storage` (gp3) → `monitoring` (kube-prometheus-stack) → `monitoring-extras` (custom alerts). First sync takes ~5–10 min. From now on every change = Git commit/PR; Argo auto-syncs with prune + self-heal.

## 8. Access (internal only — nothing is exposed)
```bash
# Argo CD UI  -> http://localhost:8080   (user: admin)
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Grafana     -> http://localhost:3000   (admin / secret from step 6)
kubectl -n monitoring port-forward svc/grafana 3000:80

# Prometheus  -> http://localhost:9090
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090

# Alertmanager-> http://localhost:9093
kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093
```
Change the Argo CD admin password after first login, then delete `argocd-initial-admin-secret`.
For shared team access later: private-only endpoint + SSM/VPN, or an **internal** ALB (`kubernetes.io/role/internal-elb` subnets are already tagged).

## 9. Validate
```bash
./scripts/validate.sh
```
Checks: Applications Synced/Healthy, pods Running, PVCs Bound, node-exporter on every node, kube-state-metrics up, zero DOWN Prometheus targets, `node_*` and `kube_*` metrics present, Watchdog firing in Alertmanager, Grafana healthy. Manual: Grafana → Dashboards → "Kubernetes / Compute Resources / Cluster" and "Node Exporter / Nodes" show data; Prometheus → Status → Targets all UP.

## 10. Troubleshooting
| Symptom | Check / fix |
|---|---|
| Node group `CREATE_FAILED: instances failed to join` | `./scripts/diagnose.sh`; NAT route, CNI policy, addon order. Destroy & recreate the node group. |
| Nodes `NotReady`, `cni plugin not initialized` | `kubectl -n kube-system logs ds/aws-node -c aws-node`; vpc-cni addon `health.issues`; node role CNI policy |
| Pod stuck `Pending` "Too many pods" | t3.large = 35 pods/node; add nodes (`node_desired_size`) |
| PVC `Pending` | `kubectl -n kube-system get pods -l app=ebs-csi-controller`; EBS CSI IRSA role; `gp3` StorageClass synced |
| `monitoring` app OutOfSync / CRD "annotation too long" | `ServerSideApply=true` must stay on |
| Operator admission webhook timeout | node SG must allow cluster SG → 8443 (module default rules; don't disable `node_security_group_enable_recommended_rules`) |
| `monitoring-extras` fails first time | CRDs not ready yet; sync-wave + retry resolves it, or re-sync |
| Argo CD can't clone repo | repo secret (step 5), NAT egress to github.com |

## 11. Teardown
```bash
kubectl delete -f gitops/bootstrap/root-app.yaml      # prunes apps (PVCs/EBS volumes deleted: reclaimPolicy Delete)
helm -n argocd uninstall argocd
cd terraform && terraform destroy
```

## Notes / assumptions
- Versions pinned in this repo (EKS module `~> 20.37`, VPC `~> 5.21`, kube-prometheus-stack `75.15.1`) were written without registry access: confirm with `terraform init -upgrade` and `helm search repo` and pin what you test.
- Dev sizing: 7-day Prometheus retention on a 10 Gi gp3 volume, single replicas, no HA, no external alert receiver.


# Food Delivery Demo for EKS + Argo CD

Demo only: frontend (NGINX), restaurant API (Flask), order API (Flask), Redis (temporary data). All Services are ClusterIP. No Ingress, LoadBalancer, or NodePort.

## Build and push images (Git Bash)
Confirm AWS account first: `aws sts get-caller-identity`. Replace the account ID in the three deployment YAMLs if needed.

```bash
export AWS_REGION=ap-southeast-2
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
for repo in food-delivery-frontend food-delivery-restaurant-api food-delivery-order-api; do
  aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$repo" --image-scanning-configuration scanOnPush=true --region "$AWS_REGION"
done
docker build -t "$ECR_REGISTRY/food-delivery-restaurant-api:0.1.0" applications/food-delivery/restaurant-api
docker build -t "$ECR_REGISTRY/food-delivery-order-api:0.1.0" applications/food-delivery/order-api
docker build -t "$ECR_REGISTRY/food-delivery-frontend:0.1.0" applications/food-delivery/frontend
docker push "$ECR_REGISTRY/food-delivery-restaurant-api:0.1.0"
docker push "$ECR_REGISTRY/food-delivery-order-api:0.1.0"
docker push "$ECR_REGISTRY/food-delivery-frontend:0.1.0"
```
Worker nodes need ECR image-pull permissions (e.g. AmazonEC2ContainerRegistryReadOnly). Never store AWS credentials in manifests.

## Add to existing GitOps repo
Copy `applications/food-delivery/` into the repository root. Copy `gitops/apps/food-delivery.yaml` into your existing `gitops/apps/` folder. The Argo Application points to `https://github.com/Bhaskara212/platform-dev-eks-gitops.git`, branch `main`; change URL/branch if yours differs. If the root app does not discover `gitops/apps/`, add this Application to the path the root app watches. Do not create a second root app.

Build/push images before syncing. Commit and push to the branch configured in the Application:
```bash
git add applications/food-delivery gitops/apps/food-delivery.yaml
git commit -m "Add food delivery demo"
git push origin main
kubectl apply -f gitops/apps/food-delivery.yaml
```
If testing on `feature/new-eks-cluster`, push that branch and temporarily set `targetRevision: feature/new-eks-cluster`, then switch back after merge.

## Validate and open
```bash
kubectl get applications -n argocd
kubectl describe application food-delivery -n argocd
kubectl get pods,svc -n food-delivery
kubectl get events -n food-delivery --sort-by=.metadata.creationTimestamp
kubectl rollout status deployment/frontend -n food-delivery --timeout=180s
kubectl rollout status deployment/restaurant-api -n food-delivery --timeout=180s
kubectl rollout status deployment/order-api -n food-delivery --timeout=180s
kubectl rollout status deployment/redis -n food-delivery --timeout=180s
```
Port-forward (keep terminal open), then visit http://localhost:8088:
```bash
kubectl -n food-delivery port-forward svc/frontend 8088:80
```
Test APIs from a second terminal:
```bash
curl -s http://localhost:8088/api/restaurants
curl -s -X POST http://localhost:8088/api/orders -H 'Content-Type: application/json' -d '{"customer":"Demo Customer","items":[{"id":"masala-dosa","quantity":2},{"id":"filter-coffee","quantity":1}]}'
curl -s http://localhost:8088/api/orders
```
Monitoring/troubleshooting:
```bash
kubectl top pods -n food-delivery
kubectl logs deployment/frontend -n food-delivery
kubectl logs deployment/restaurant-api -n food-delivery
kubectl logs deployment/order-api -n food-delivery
kubectl logs deployment/redis -n food-delivery
```
All app services are internal. Redis uses `emptyDir` and no persistence; data is lost if the Redis pod is replaced. This PoC has no auth, payments, TLS, or production durability.
