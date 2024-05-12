#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Set default values for parameters
AWS_REGION="us-west-2"
TEMPLATE_FILE="stackset.yml"
STACKSET_NAME="LilyHelloWorldStackSet"
TARGET_ACCOUNT_IDS=""
ROLE_NAME="LilyStackSetExecutionRole"

# Parse command-line parameters
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -r|--region)
      AWS_REGION="$2"
      shift
      shift
      ;;
    -t|--template)
      TEMPLATE_FILE="$2"
      shift
      shift
      ;;
    -n|--name)
      STACKSET_NAME="$2"
      shift
      shift
      ;;
    -a|--accounts)
      TARGET_ACCOUNT_IDS="$2"
      shift
      shift
      ;;
    *)
      echo "Unknown parameter: $1"
      exit 1
      ;;
  esac
done

# Set the default target account ID if not provided
if [ -z "$TARGET_ACCOUNT_IDS" ]; then
  TARGET_ACCOUNT_IDS=$(aws sts get-caller-identity --query 'Account' --output text)
fi

# Check if the role already exists
aws iam get-role --role-name $ROLE_NAME > /dev/null 2>&1

if [ $? -ne 0 ]; then
  echo "Creating role $ROLE_NAME..."

    # Define the trust policy for the role
  TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
          "Service": "cloudformation.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

  # Create the role
  aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document "$TRUST_POLICY"
else
  echo "Role $ROLE_NAME already exists, skipping creation."
fi

# Attach or update the permissions policy on the role
aws iam put-role-policy --role-name $ROLE_NAME --policy-name StackSetExecutionPolicy --policy-document file://stackset-execution-policy.json --overwrite

# Set the parameter overrides (if any)
PARAMETERS='ParameterKey=AWSRegion,ParameterValue='$AWS_REGION

# Create or update the StackSet
aws cloudformation create-stack-set \
  --stack-set-name $STACKSET_NAME \
  --template-body file://$TEMPLATE_FILE \
  --parameters $PARAMETERS \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --administration-role-arn $(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text) \
  --region $AWS_REGION \
  --no-execute-changeset 2>/dev/null || aws cloudformation update-stack-set --stack-set-name $STACKSET_NAME --use-previous-template --parameters $PARAMETERS --region $AWS_REGION

# Wait for the StackSet operation to complete
aws cloudformation wait stack-set-operation-complete \
  --stack-set-name $STACKSET_NAME \
  --operation-id $(aws cloudformation list-stack-set-operations --stack-set-name $STACKSET_NAME --query 'Summaries[0].OperationId' --output text) \
  --region $AWS_REGION

# Create or update stack instances in the target accounts and regions  
OPERATION_ID=$(aws cloudformation create-stack-instances \
  --stack-set-name $STACKSET_NAME \
  --accounts $TARGET_ACCOUNT_IDS \
  --regions $AWS_REGION \
  --operation-preferences FailureToleranceCount=0,MaxConcurrentCount=1 \
  --query 'OperationId' \
  --output text \
  --region $AWS_REGION 2>/dev/null) || true

if [ -n "$OPERATION_ID" ]; then
  echo "Waiting for stack instance creation/update to complete..."
  aws cloudformation wait stack-set-operation-complete \
    --stack-set-name $STACKSET_NAME \
    --operation-id $OPERATION_ID \
    --region $AWS_REGION
else
  echo "No new stack instances to create/update."  
fi
