# Day 2: S3 Cross-Region Automated Replication & Failover
  
> **AWS Services**: `Amazon S3 (CRR)`, `AWS KMS`, `AWS IAM`, `AWS Lambda`, `Amazon SNS`  

---

## 📖 Real-World Story: The $500,000 Multi-Region Outage Disaster

### 🏢 Scenario
At **PaySecure Global**, a licensed payment gateway processing over 10 million transactions daily, regulatory compliance mandated that all transaction audit logs be backed up with multi-region redundancy and encrypted using customer-managed KMS keys.

During a catastrophic regional power and network disruption in AWS `us-east-1`, PaySecure's primary data storage became temporarily unreachable. Because the engineering team relied on single-region S3 storage, the disaster recovery team spent **6 agonizing hours** attempting manual data exports and bucket synchronization. 

The application downtime caused transaction processing failures across 12 banking partners, incurring over **$500,000 in SLA non-compliance penalties** and triggering an urgent regulatory audit. The root cause analysis revealed that while SSE-KMS encryption was enabled, S3 Cross-Region Replication (CRR) was never configured because standard replication rules failed when encrypted with custom KMS keys without cross-region IAM policies.

---

## ❌ The Problem Statement

1. **Single-Region Vulnerability**: Storing critical compliance data in a single AWS region exposes business operations to regional outages and disaster scenarios.
2. **KMS Cross-Region Blockers**: Standard S3 SSE-S3 replication does not work out-of-the-box for objects encrypted with Customer Managed KMS Keys (`aws:kms`). S3 CRR requires explicit KMS decrypt permissions in the source region and KMS re-encrypt permissions in the destination region.
3. **Lack of Automated Sync Verification**: No automated monitor to audit whether S3 `ReplicationStatus` is `COMPLETED`, `PENDING`, or `FAILED` across multi-region buckets.
4. **Strict RPO/RTO Compliance Deficits**: Financial regulations require guaranteed 15-minute Recovery Point Objectives (RPO) via S3 Replication Time Control (RTC).

---

## 🛠️ The AWS Solution Architecture

```text
       [ Client Uploads / App Logs ]
                    │
                    ▼ (us-east-1)
 ┌──────────────────────────────────────────────┐
 │ Primary S3 Bucket: compliance-primary-east1  │ ◄── KMS Key (us-east-1)
 └──────────────────┬───────────────────────────┘
                    │
                    │ (S3 CRR + RTC 15-min SLA)
                    ▼
 ┌──────────────────────────────────────────────┐
 │ IAM Replication Role                         │ ──► [ Decrypt via Primary KMS ]
 └──────────────────┬───────────────────────────┘ ──► [ Re-encrypt via Replica KMS ]
                    │
                    ▼ (us-west-2)
 ┌──────────────────────────────────────────────┐
 │ Replica S3 Bucket: compliance-replica-west2  │ ◄── KMS Key (us-west-2)
 └──────────────────┬───────────────────────────┘
                    │
                    │ (Nightly / Automated Audit)
                    ▼
 ┌──────────────────────────────────────────────┐
 │ Python Boto3 Failover Auditor (Lambda/Script)│ ──► [ Check ReplicationStatus ]
 └──────────────────┬───────────────────────────┘
                    │
                    ▼
 ┌──────────────────────────────────────────────┐
 │ Amazon SNS Topic                             │ ──► [ Email / Slack Alerts ]
 └──────────────────────────────────────────────┘
```

### 💡 AWS Services Breakdown:
- **Amazon S3 Cross-Region Replication (CRR)**: Automatically and asynchronously copies objects across S3 buckets in different AWS regions (`us-east-1` ➔ `us-west-2`).
- **AWS KMS (Customer Managed Keys)**: Provides separate cryptographic keys in each region, forcing automated decryption in source and re-encryption in destination.
- **AWS IAM**: Grants S3 CRR service permissions (`s3:GetReplicationConfiguration`, `s3:ReplicateObject`, `kms:Decrypt`, `kms:Encrypt`).
- **S3 Replication Time Control (RTC)**: Guarantees 99.99% of objects are replicated within 15 minutes, backed by an AWS SLA.
- **Python Boto3 Auditor**: Inspects object replication headers (`COMPLETED`, `PENDING`, `FAILED`) and publishes SNS failure alerts.


## 🚀 Step-by-Step Implementation Guide

### Step 1: Provision Multi-Region Infrastructure with Terraform
1. Deploy the Terraform IaC code in [`code/terraform/main.tf`](https://github.com/imsanju02k/Cloud-Projects/blob/main/Day-2/S3%20Cross-Region%20Replication%20%26%20KMS%20Failover/code/terraform/main.tf).
2. Terraform provisions:
   - KMS Key in `us-east-1` & KMS Key in `us-west-2`.
   - Primary S3 Bucket (`us-east-1`) & Replica S3 Bucket (`us-west-2`) with S3 Versioning enabled.
   - IAM Role with cross-region S3 replication & KMS re-encryption permissions.
   - `aws_s3_bucket_replication_configuration` with S3 RTC 15-minute metrics enabled.

### Step 2: Execute Automated Replication Monitoring
1. Set environment variables:
   ```bash
   export PRIMARY_REGION="us-east-1"
   export REPLICA_REGION="us-west-2"
   export PRIMARY_BUCKET_NAME="compliance-primary-data-production-east1"
   export REPLICA_BUCKET_NAME="compliance-replica-dr-production-west2"
   ```
2. Run the Boto3 auditor script provided in [`code/replication_failover_monitor.py`](https://github.com/imsanju02k/Cloud-Projects/blob/main/Day-2/S3%20Cross-Region%20Replication%20%26%20KMS%20Failover/code/replication_failover_monitor.py).

### Step 3: Test Cross-Region Disaster Recovery Failover
1. Upload a KMS-encrypted sample file to the primary bucket:
   ```bash
   aws s3 cp sample_contract.pdf s3://compliance-primary-data-production-east1/ --sse aws:kms
   ```
2. Verify object replication status:
   ```bash
   aws s3api head-object --bucket compliance-primary-data-production-east1 --key sample_contract.pdf --query "ReplicationStatus"
   ```
3. Confirm object presence and re-encryption in `us-west-2`:
   ```bash
   aws s3api head-object --bucket compliance-replica-dr-production-west2 --key sample_contract.pdf --region us-west-2
   ```

---

## 💻 Code & Infrastructure Artifacts

- **Terraform Multi-Region IaC Blueprint**: [`code/terraform/main.tf`](https://github.com/imsanju02k/Cloud-Projects/blob/main/Day-2/S3%20Cross-Region%20Replication%20%26%20KMS%20Failover/code/terraform/main.tf)
- **Python Boto3 Replication Monitor**: [`code/replication_failover_monitor.py`](https://github.com/imsanju02k/Cloud-Projects/blob/main/Day-2/S3%20Cross-Region%20Replication%20%26%20KMS%20Failover/code/replication_failover_monitor.py)

---

## 🧠 Key Takeaways & Interview Questions

### ❓ Question 1: How do you replicate S3 objects encrypted with custom KMS keys across regions?
> **Answer Key**:  
> *"Default S3 replication does not copy objects encrypted with KMS Customer Managed Keys unless explicitly configured. To enable this, you must: (1) enable `sse_kms_encrypted_objects` in the replication rule, (2) provide a destination KMS key ARN in the rule configuration for re-encryption, and (3) update the IAM replication role policy with `kms:Decrypt` permissions on the source KMS key and `kms:Encrypt`/`kms:GenerateDataKey` permissions on the destination KMS key."*

### ❓ Question 2: What is S3 Replication Time Control (RTC) and when would you use it?
> **Answer Key**:  
> *"S3 RTC is an add-on feature for S3 Cross-Region and Same-Region Replication that guarantees 99.99% of new objects are replicated within 15 minutes, backed by an AWS SLA. It provides real-time CloudWatch metrics for replication latency, pending bytes, and pending operations. It is essential for financial, healthcare, and enterprise applications with strict Recovery Point Objectives (RPO)."*
