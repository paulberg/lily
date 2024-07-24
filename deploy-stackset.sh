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

# Set the default target account ID if not provided
if [ -z "$TARGET_ACCOUNT_IDS" ]; then
  TARGET_ACCOUNT_IDS=$(aws sts get-caller-identity --query 'Account' --output text)
fi


# Check if the AWSCloudFormationStackSetAdministrationRole exists
aws iam get-role --role-name AWSCloudFormationStackSetAdministrationRole > /dev/null 2>&1 || {
    echo "Creating role AWSCloudFormationStackSetAdministrationRole..."

  # Define the trust policy for the AWSCloudFormationStackSetAdministrationRole
  ADMIN_TRUST_POLICY=$(cat <<EOF
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

  # Create the AWSCloudFormationStackSetAdministrationRole
  aws iam create-role --role-name AWSCloudFormationStackSetAdministrationRole --assume-role-policy-document "$ADMIN_TRUST_POLICY"
}

# Check if the AWSCloudFormationStackSetExecutionRole exists
aws iam get-role --role-name AWSCloudFormationStackSetExecutionRole > /dev/null 2>&1 || {
    echo "Creating role AWSCloudFormationStackSetExecutionRole..."

  # Define the trust policy for the AWSCloudFormationStackSetExecutionRole
  EXECUTION_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${TARGET_ACCOUNT_IDS}:role/AWSCloudFormationStackSetAdministrationRole"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

  # Create the AWSCloudFormationStackSetExecutionRole
  aws iam create-role --role-name AWSCloudFormationStackSetExecutionRole --assume-role-policy-document "$EXECUTION_TRUST_POLICY"
}

# Attach the permissions policy to the AWSCloudFormationStackSetAdministrationRole
aws iam put-role-policy --role-name AWSCloudFormationStackSetAdministrationRole --policy-name StackSetAdministrationPolicy --policy-document file://stackset-administration-policy.json

# Attach the permissions policy to the AWSCloudFormationStackSetExecutionRole
aws iam put-role-policy --role-name AWSCloudFormationStackSetExecutionRole --policy-name StackSetExecutionPolicy --policy-document file://stackset-execution-policy.json

# Set the parameter overrides (if any)
PARAMETERS='ParameterKey=AWSRegion,ParameterValue='$AWS_REGION

# Create or update the StackSet
if aws cloudformation describe-stack-set --stack-set-name $STACKSET_NAME --region $AWS_REGION >/dev/null 2>&1; then
  # Stack set exists, update it
  aws cloudformation update-stack-set \
    --stack-set-name $STACKSET_NAME \
    --use-previous-template \
    --parameters $PARAMETERS \
    --region $AWS_REGION
else
  # Stack set doesn't exist, create it
  aws cloudformation create-stack-set \
    --stack-set-name $STACKSET_NAME \
    --template-body file://$TEMPLATE_FILE \
    --parameters $PARAMETERS \
    --permission-model SELF_MANAGED \
    --capabilities CAPABILITY_IAM \
    --region $AWS_REGION
fi

# Assume the execution role
#ASSUMED_ROLE=$(aws sts assume-role --role-arn arn:aws:iam::$TARGET_ACCOUNT_IDS:role/AWSCloudFormationStackSetExecutionRole --role-session-name StackSetExecutionSession --query 'Credentials.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey,SessionToken:SessionToken}' --output json)
ASSUMED_ROLE=$(aws sts assume-role --role-arn arn:aws:iam::$TARGET_ACCOUNT_IDS:role/AWSCloudFormationStackSetAdministrationRole --role-session-name StackSetAdministrationSession --query 'Credentials.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey,SessionToken:SessionToken}' --output json)

# Extract the access key, secret key, and session token from the assumed role
ACCESS_KEY=$(echo $ASSUMED_ROLE | jq -r '.AccessKeyId')
SECRET_KEY=$(echo $ASSUMED_ROLE | jq -r '.SecretAccessKey')
SESSION_TOKEN=$(echo $ASSUMED_ROLE | jq -r '.SessionToken')

# Create stack instances in the target accounts and regions
OPERATION_ID=$(aws cloudformation create-stack-instances \
  --stack-set-name $STACKSET_NAME \
    --accounts $TARGET_ACCOUNT_IDS \
      --regions $AWS_REGION \
        --operation-preferences FailureToleranceCount=0 \
          --query 'OperationId' \
            --output text \
              --region $AWS_REGION \
                --call-as DELEGATED_ADMIN \
                  --capabilities CAPABILITY_IAM \
                    --access-key-id $ACCESS_KEY \
                      --secret-access-key $SECRET_KEY \
                        --session-token $SESSION_TOKEN)

# Wait for the stack instance creation to complete
echo "Waiting for stack instance creation to complete..."
while true; do
  STATUS=$(aws cloudformation describe-stack-set-operation \
    --stack-set-name $STACKSET_NAME \
    --operation-id $OPERATION_ID \
    --query 'StackSetOperation.Status' \
    --output text \
    --region $AWS_REGION)

  if [[ $STATUS == "SUCCEEDED" ]]; then
    echo "Stack instance creation completed successfully."
    break
  elif [[ $STATUS == "FAILED" || $STATUS == "STOPPED" ]]; then
    echo "Stack instance creation failed or stopped. Please check the AWS Management Console for more details."
    break
  else
    echo "Stack instance creation is still in progress. Waiting for 10 seconds..."
    sleep 10
  fi
done
