# vams-isaac-lab-so-arm101-reach

> ⚠ Skeleton (WIP). Contents will be finalized during the implementation phase. Not yet committed/pushed.

Configuration, procedures, and helper scripts for running reinforcement learning of the
SO-ARM101 (Isaac Lab / Reach-Grasp, PPO) using the NVIDIA Isaac Lab training feature of
VAMS (Visual Asset Management System).

Related blog post (ja): "[VAMS] NVIDIA Isaac Lab トレーニング機能で SO-ARM101 を学習させてみました"

## What this repository is

It does not bundle VAMS itself or the training environment. It is the "glue" that connects them.

| Component | Source | Role here |
|---|---|---|
| VAMS core | [awslabs/visual-asset-management-system](https://github.com/awslabs/visual-asset-management-system) (2.4.0+) | Cloned and used. Config diffs live in `config/` |
| Training env (base) | [MuammerBay/isaac_so_arm101](https://github.com/MuammerBay/isaac_so_arm101) (BSD-3-Clause) | Fetched and packaged by `custom-env/` scripts |
| Reach-Grasp diff | [furuya02/isaac-lab-so-arm101-reach-grasp](https://github.com/furuya02/isaac-lab-so-arm101-reach-grasp) | Overlaid onto the base to form the custom env |

## Directory layout (planned)

```
vams-isaac-lab-so-arm101-reach/
├── config/        # VAMS config.json diffs/templates (enable Isaac Lab / VPC / OpenSearch=none)
├── custom-env/    # Custom env packaging (setup.py, apply-diff -> tar.gz scripts)
├── scripts/       # Helpers: deploy / destroy / quota check
└── docs/          # Diagrams and notes
```

## Prerequisites (researched; see blog docs for details)

- VAMS 2.4.0+ (latest v2.5.1). The Isaac Lab pipeline container is pinned to **Isaac Lab 2.3.0**.
- The custom env (fork) is also Isaac Lab 2.3.0 / Isaac Sim 5.1.0 -> **versions match**.
- Required config: `app.pipelines.useIsaacLabTraining.{enabled:true, acceptNvidiaEula:true}`, VPC mode required.
- GPU: g5/g6/g6e available in ap-northeast-1; vCPU quota sufficient (no increase needed).

## Quick start (details & gotchas in `docs/runbook.md`)

Prereqs: Node 20+ / Python 3.12+ / Docker / AWS CDK CLI / jq / git / AWS credentials.

```bash
git clone <this-repo> && cd vams-isaac-lab-so-arm101-reach

# 0) NGC login (required to pull the Isaac Lab base image)
docker login nvcr.io   # Username: $oauthtoken / Password: NGC API key

# 1) Quota check (optional, read-only)
bash scripts/check-quota.sh

# 2) Deploy (CHARGES START HERE: clones VAMS, auto-applies patches, cdk deploy)
bash scripts/deploy.sh
#   Note the Outputs: WebsiteEndpointURL / AuthCognitoUserPoolId / AssetS3Bucket

# 3) Set admin password -> log into the Web UI
aws cognito-idp admin-set-user-password --user-pool-id <UserPoolId> \
  --username administrator --password '<password-with-uppercase>' --permanent --region ap-northeast-1

# 4) Build the custom env tar.gz -> upload to the asset bucket
bash custom-env/build-custom-env.sh
aws s3 cp custom-env/dist/so-arm101-reach-grasp-env.tar.gz \
  s3://<AssetS3Bucket>/custom-env/so-arm101-reach-grasp-env.tar.gz --region ap-northeast-1
```

5. In the Web UI: create a Database / Asset -> set pipeline `isaaclab-training` Input Parameters for
   SO-ARM101 (**`customEnvironmentS3Uri` goes INSIDE `trainingConfig`**) -> run a GLOBAL workflow.
   See `docs/runbook.md` "Phase 2".
6. **Always run `bash scripts/destroy.sh`** after verification.

> The patches deploy.sh applies to VAMS (required for custom envs) and all gotcha fixes are
> documented in `docs/runbook.md`.

## Verification

- Batch log `/aws/batch/job` shows `Learning iteration .../500` plus SO-ARM101 reward terms
  (`end_effector_position_tracking`, etc.) -> training succeeded.
- The asset's File Manager gets `checkpoints/model_*.pt` / `metrics.csv` / `train-config.json`.
- Note: VAMS may show SUCCEEDED even when training actually failed (false success) — always check the Batch log.

## ⚠ Cost and teardown (important)

A running VAMS stack incurs continuous charges (VPC / NAT Gateway, etc.). After verification,
**always run `bash scripts/destroy.sh`** (which runs `cdk destroy --all`). Do not leave it running.
`destroy.sh` prompts for y/N confirmation (skip with `FORCE=1` or `-y`).

## Troubleshooting: when destroy fails

VAMS destroy can stop at `DELETE_FAILED` on specific resources. The biggest cost driver,
the **NAT Gateway, is usually deleted early**, so first confirm the NAT is gone, then clean up the rest.

### 0. First confirm the NAT (cost) is stopped
```bash
aws ec2 describe-nat-gateways --region ap-northeast-1 \
  --filter Name=state,Values=pending,available \
  --query 'NatGateways[].{Id:NatGatewayId,State:State}' --output table
# Empty (only Deleted) => main charges stopped
```

### 1. ApiGatewayV2 Authorizer InternalFailure
Symptom: `AWS::ApiGatewayV2::Authorizer` `InternalFailure` -> parent (Api nested / core) `DELETE_FAILED`.
```bash
aws apigatewayv2 get-apis --region ap-northeast-1 --query 'Items[].{Name:Name,ApiId:ApiId}' --output table
aws apigatewayv2 get-authorizers --api-id <ApiId> --region ap-northeast-1 \
  --query 'Items[].{Name:Name,Id:AuthorizerId}' --output table
aws apigatewayv2 delete-authorizer --api-id <ApiId> --authorizer-id <AuthorizerId> --region ap-northeast-1
bash scripts/destroy.sh -y
```

### 1b. Subnet "has dependencies" and cannot be deleted (leftover VPC endpoint ENI)
Symptom: `AWS::EC2::Subnet ... has dependencies and cannot be deleted` -> VPCBuilder/core `DELETE_FAILED`.
Cause: a VPC endpoint ENI (`available`) still sits in the subnet.
```bash
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=subnet-id,Values=<subnet-id> \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description}' --output table
aws ec2 describe-vpc-endpoints --region ap-northeast-1 --filters Name=vpc-id,Values=<vpc-id> \
  --query 'VpcEndpoints[].VpcEndpointId' --output text
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids <vpce-id> --region ap-northeast-1
aws ec2 delete-network-interface --network-interface-id <eni-id> --region ap-northeast-1   # if an available ENI remains
bash scripts/destroy.sh -y
```

### 2. Location Service API key "already exists" on re-deploy
Symptom: leftover from a prior destroy makes re-deploy fail with
`AWS::Location::APIKey ... already exists` -> core `ROLLBACK_COMPLETE`.
```bash
aws location list-keys --region ap-northeast-1 --query 'Entries[].KeyName' --output table
aws location delete-key --key-name <KeyName> --region ap-northeast-1 --force-delete
aws cloudformation delete-stack --stack-name vams-core-prod-ap-northeast-1 --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name vams-core-prod-ap-northeast-1 --region ap-northeast-1
bash scripts/deploy.sh
```

### 3. Orphan resources left after destroy (manual cleanup)
```bash
# Any vams stacks remaining (check both ap-northeast-1 and us-east-1)
aws cloudformation list-stacks --region ap-northeast-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query 'StackSummaries[?contains(StackName,`vams`)].{Name:StackName,Status:StackStatus}' --output table
# Leftover S3 buckets (empty + delete)
for B in $(aws s3api list-buckets --query 'Buckets[?contains(Name,`vams`)].Name' --output text); do
  echo "== $B =="; aws s3 rb "s3://$B" --force
done
# Orphan Isaac Lab image in the shared CDK assets ECR repo (keep the repo; delete only large orphan images)
aws ecr describe-images --repository-name cdk-hnb659fds-container-assets-<ACCOUNT_ID>-ap-northeast-1 \
  --region ap-northeast-1 \
  --query 'sort_by(imageDetails,&imageSizeInBytes)[].{Pushed:imagePushedAt,SizeMB:imageSizeInBytes,Digest:imageDigest}' --output table
```

> Note: the WAF stack is created in us-east-1 by design (for CloudFront). `cdk destroy --all` removes both
> regions, but verify us-east-1 too if anything remains.

## License

The custom env is a derivative of [MuammerBay/isaac_so_arm101](https://github.com/MuammerBay/isaac_so_arm101)
(BSD-3-Clause, Copyright (c) 2025 Muammer Bay (LycheeAI), Louis Le Lay). Preserve the copyright
notice and license.
