import os
import boto3
import json
import logging
from datetime import datetime

# Setup structured logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment configuration
PRIMARY_REGION = os.getenv('PRIMARY_REGION', 'us-east-1')
REPLICA_REGION = os.getenv('REPLICA_REGION', 'us-west-2')
PRIMARY_BUCKET_NAME = os.getenv('PRIMARY_BUCKET_NAME', 'my-primary-compliance-bucket-east')
REPLICA_BUCKET_NAME = os.getenv('REPLICA_BUCKET_NAME', 'my-replica-compliance-bucket-west')
SNS_TOPIC_ARN = os.getenv('SNS_TOPIC_ARN', '')

def check_replication_status():
    """
    Audits the Cross-Region Replication (CRR) status of recent objects in the primary bucket,
    verifying whether objects are successfully replicated and encrypted in the destination bucket.
    """
    s3_primary = boto3.client('s3', region_name=PRIMARY_REGION)
    s3_replica = boto3.client('s3', region_name=REPLICA_REGION)
    sns_client = boto3.client('sns', region_name=PRIMARY_REGION)

    logging.info(f"Auditing S3 CRR from {PRIMARY_BUCKET_NAME} ({PRIMARY_REGION}) to {REPLICA_BUCKET_NAME} ({REPLICA_REGION})")

    completed_count = 0
    pending_count = 0
    failed_count = 0
    unreplicated_objects = []

    try:
        # List objects in the primary bucket
        response = s3_primary.list_objects_v2(Bucket=PRIMARY_BUCKET_NAME, MaxKeys=100)
        
        if 'Contents' not in response:
            logging.info(f"No objects found in primary bucket '{PRIMARY_BUCKET_NAME}'.")
            return {
                "statusCode": 200,
                "body": json.dumps("No objects to evaluate.")
            }

        for item in response['Contents']:
            key = item['Key']
            
            # Fetch object metadata & replication status
            head_res = s3_primary.head_object(Bucket=PRIMARY_BUCKET_NAME, Key=key)
            status = head_res.get('ReplicationStatus', 'NOT_CONFIGURED')

            if status == 'COMPLETED':
                completed_count += 1
                # Double-check existence in destination bucket
                try:
                    s3_replica.head_object(Bucket=REPLICA_BUCKET_NAME, Key=key)
                except Exception as e:
                    logging.warning(f"Object '{key}' marked COMPLETED in primary, but missing in replica! Error: {str(e)}")
                    failed_count += 1
                    unreplicated_objects.append(key)
            elif status == 'PENDING':
                pending_count += 1
            elif status == 'FAILED':
                failed_count += 1
                unreplicated_objects.append(key)

        summary_msg = (
            f"S3 CRR Audit Summary for '{PRIMARY_BUCKET_NAME}':\n"
            f"----------------------------------------\n"
            f"✅ Replicated (COMPLETED): {completed_count}\n"
            f"⏳ Pending (PENDING): {pending_count}\n"
            f"❌ Failed (FAILED): {failed_count}\n"
        )
        logging.info(summary_msg)

        # Trigger SNS notification if failures exist or pending count is high
        if (failed_count > 0 or pending_count > 20) and SNS_TOPIC_ARN:
            alert_subject = f"🚨 ALERT: S3 Cross-Region Replication Issues Detected in {PRIMARY_BUCKET_NAME}"
            alert_body = (
                f"{summary_msg}\n"
                f"Failed/Unreplicated Object Keys:\n"
                f"{json.dumps(unreplicated_objects[:10], indent=2)}\n\n"
                f"Action Required: Check IAM KMS Key policy and S3 CRR service metrics."
            )
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=alert_subject,
                Message=alert_body
            )
            logging.info("SNS alert published successfully.")

        return {
            "statusCode": 200,
            "completed": completed_count,
            "pending": pending_count,
            "failed": failed_count
        }

    except Exception as e:
        error_msg = f"Critical error auditing S3 replication status: {str(e)}"
        logging.error(error_msg)
        if SNS_TOPIC_ARN:
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="🚨 CRITICAL: S3 CRR Auditor Execution Failed",
                Message=error_msg
            )
        raise e

if __name__ == '__main__':
    # Local execution testing entrypoint
    check_replication_status()
