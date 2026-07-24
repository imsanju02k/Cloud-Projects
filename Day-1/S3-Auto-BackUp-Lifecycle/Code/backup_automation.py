import os
import json
import logging
import boto3
from botocore.exceptions import ClientError

# Configure Logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS SDK Clients
s3_client = boto3.client('s3')
sns_client = boto3.client('sns')

# SNS Topic ARN from Environment Variables
SNS_TOPIC_ARN = os.getenv('SNS_TOPIC_ARN', 'arn:aws:sns:us-east-1:123456789012:s3-compliance-alerts')

def check_bucket_lifecycle(bucket_name):
    """Check if the bucket has an active Lifecycle Configuration."""
    try:
        lifecycle = s3_client.get_bucket_lifecycle_configuration(Bucket=bucket_name)
        return True, lifecycle.get('Rules', [])
    except ClientError as e:
        if e.response['Error']['Code'] == 'NoSuchLifecycleConfiguration':
            return False, []
        logger.error(f"Error checking lifecycle for {bucket_name}: {e}")
        return False, []

def check_bucket_versioning(bucket_name):
    """Check if bucket versioning is Enabled."""
    try:
        response = s3_client.get_bucket_versioning(Bucket=bucket_name)
        status = response.get('Status', 'Disabled')
        return status == 'Enabled'
    except ClientError as e:
        logger.error(f"Error checking versioning for {bucket_name}: {e}")
        return False

def lambda_handler(event, context):
    """
    AWS Lambda Handler: Audits all S3 buckets in the account for compliance.
    Sends SNS notification if non-compliant buckets are found.
    """
    logger.info("Starting S3 Storage & Compliance Audit...")
    
    non_compliant_buckets = []

    try:
        buckets_response = s3_client.list_buckets()
        buckets = buckets_response.get('Buckets', [])
        
        logger.info(f"Total buckets found: {len(buckets)}")

        for bucket in buckets:
            bucket_name = bucket['Name']
            has_lifecycle, rules = check_bucket_lifecycle(bucket_name)
            is_versioned = check_bucket_versioning(bucket_name)

            issues = []
            if not has_lifecycle:
                issues.append("Missing S3 Lifecycle Rules (No Auto-Glacier Archival)")
            if not is_versioned:
                issues.append("S3 Versioning Disabled (Vulnerable to Deletion/Ransomware)")

            if issues:
                non_compliant_buckets.append({
                    "BucketName": bucket_name,
                    "Issues": issues
                })

        # Send SNS Alert if any non-compliant buckets exist
        if non_compliant_buckets:
            message = (
                "⚠️ AWS S3 SECURITY & COST COMPLIANCE AUDIT ALERT ⚠️\n\n"
                f"Scanned {len(buckets)} buckets. Found {len(non_compliant_buckets)} NON-COMPLIANT buckets:\n\n"
            )
            for item in non_compliant_buckets:
                message += f"🪣 Bucket: {item['BucketName']}\n"
                for issue in item['Issues']:
                    message += f"   - ❌ {issue}\n"
                message += "\n"

            message += "Action Required: Enforce Terraform lifecycle rules and enable versioning.\n"

            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="[AWS Cloud Automation] Daily S3 Storage Audit Alert",
                Message=message
            )
            logger.info("SNS Alert sent successfully.")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "S3 Audit Complete",
                "scanned_buckets": len(buckets),
                "non_compliant_buckets": len(non_compliant_buckets)
            })
        }

    except Exception as e:
        logger.error(f"Fatal error during audit: {str(e)}")
        raise e

if __name__ == "__main__":
    # Local Testing Execution
    print("Executing local audit test...")
    # lambda_handler({}, None)
