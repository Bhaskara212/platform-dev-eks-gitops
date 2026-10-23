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

> EKS version: `cluster_version` defaults to 1.34. Confirm it is still in **standard** support (extended support costs extra): `aws eks describe-cluster-versions --region ap-southeast-2` / EKS docs.

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
