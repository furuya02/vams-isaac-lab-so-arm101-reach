#!/usr/bin/env bash
# GPU vCPU クォータと GPU インスタンス在庫を確認（read-only・課金なし）
set -euo pipefail
REGION="${AWS_REGION:-ap-northeast-1}"

echo "== Caller =="
aws sts get-caller-identity --output table

echo "== On-Demand G/VT vCPU quota (L-DB2E81BA) =="
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
  --region "$REGION" --query 'Quota.{Name:QuotaName,Value:Value}' --output table

echo "== Spot G/VT vCPU quota (L-3819A6DF) =="
aws service-quotas get-service-quota --service-code ec2 --quota-code L-3819A6DF \
  --region "$REGION" --query 'Quota.{Name:QuotaName,Value:Value}' --output table

echo "== GPU instance availability in $REGION =="
aws ec2 describe-instance-type-offerings --location-type region --region "$REGION" \
  --filters "Name=instance-type,Values=g6.2xlarge,g6.4xlarge,g6e.2xlarge,g6e.12xlarge,g5.2xlarge,g5.4xlarge" \
  --query 'sort_by(InstanceTypeOfferings,&InstanceType)[].InstanceType' --output table
