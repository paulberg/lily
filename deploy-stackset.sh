#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Set default values for parameters
AWS_REGION="us-west-2"
TEMPLATE_FILE="stackset.yml"
STACKSET_NAME="LilyHelloWorldStackSet"
TARGET_ACCOUNT_IDS=""

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

# Validate required parameters
if [ -z "$TARGET_ACCOUNT_IDS" ]; then
  echo "Error: Target account IDs are required. Use the -a or --accounts parameter."
    exit 1
  fi

# Set the parameter overrides (if any)
PARAMETERS='ParameterKey=AWSRegion,ParameterValue='$AWS_REGION

# Create the StackSet
aws cloudformation create-stack-set \
  --stack-set-name $STACKSET_NAME \
  --template-body file://$TEMPLATE_FILE \
  --parameters $PARAMETERS \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --region $AWS_REGION

# Wait for the StackSet to be created
aws cloudformation wait stack-set-operation-complete \
  --stack-set-name $STACKSET_NAME \
  --operation-id $(aws cloudformation list-stack-set-operations --stack-set-name $STACKSET_NAME --query 'Summaries[0].OperationId' --output text) \
  --region $AWS_REGION

# Create stack instances in the target accounts and regions
aws cloudformation create-stack-instances \
  --stack-set-name $STACKSET_NAME \
  --accounts $TARGET_ACCOUNT_IDS \
  --regions $AWS_REGION \
  --operation-preferences FailureToleranceCount=0,MaxConcurrentCount=1 \
  --region $AWS_REGION
