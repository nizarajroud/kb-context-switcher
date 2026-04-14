#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

# Check if fzf is installed
if ! command -v fzf &> /dev/null; then
    echo "Error: fzf is not installed. Install with: sudo apt install fzf"
    exit 1
fi

show_menu() {
    echo "Create New Project"
    echo "Switch Project"
    echo "Update Agent Instructions"
    echo "List Projects"
    echo "Exit"
}

list_projects() {
    aws bedrock-agent list-data-sources \
        --knowledge-base-id ${KB_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query 'dataSourceSummaries[*].name' \
        --output text | tr '\t' '\n' | sed 's/-source$//'
}

create_project() {
    read -p "Project name: " PROJECT_NAME

    if [ -z "$PROJECT_NAME" ]; then
        echo "Error: Project name required"
        return
    fi

    RAND=$RANDOM
    S3_BUCKET="${PROJECT_NAME}-${RAND}"
    AUDIO_BUCKET="${PROJECT_NAME}-audio-${RAND}"

    # Create S3 bucket if needed
    if ! aws s3 ls "s3://${S3_BUCKET}" --region ${REGION} --profile ${PROFILE} 2>/dev/null; then
        echo "Creating S3 bucket: ${S3_BUCKET}"
        aws s3 mb "s3://${S3_BUCKET}" --region ${REGION} --profile ${PROFILE}
        aws s3api put-bucket-versioning \
            --bucket ${S3_BUCKET} \
            --versioning-configuration Status=Enabled \
            --region ${REGION} \
            --profile ${PROFILE}
    fi

    # Create audio S3 bucket if needed
    if ! aws s3 ls "s3://${AUDIO_BUCKET}" --region ${REGION} --profile ${PROFILE} 2>/dev/null; then
        echo "Creating audio S3 bucket: ${AUDIO_BUCKET}"
        aws s3 mb "s3://${AUDIO_BUCKET}" --region ${REGION} --profile ${PROFILE}
        aws s3api put-bucket-versioning \
            --bucket ${AUDIO_BUCKET} \
            --versioning-configuration Status=Enabled \
            --region ${REGION} \
            --profile ${PROFILE}
    fi
    
    # Create audio bucket if requested
    if [[ "$CREATE_AUDIO" =~ ^[Yy]$ ]]; then
        AUDIO_BUCKET="audio-${S3_BUCKET}"
        if ! aws s3 ls "s3://${AUDIO_BUCKET}" --region ${REGION} --profile ${PROFILE} 2>/dev/null; then
            echo "Creating audio S3 bucket: ${AUDIO_BUCKET}"
            aws s3 mb "s3://${AUDIO_BUCKET}" --region ${REGION} --profile ${PROFILE}
            aws s3api put-bucket-versioning \
                --bucket ${AUDIO_BUCKET} \
                --versioning-configuration Status=Enabled \
                --region ${REGION} \
                --profile ${PROFILE}
        fi
        
        # Ask to reconfigure Lambda
        read -p "Configure Lambda and S3 trigger for this project? (y/n): " RECONFIG_LAMBDA
        if [[ "$RECONFIG_LAMBDA" =~ ^[Yy]$ ]]; then
            if [ -z "$TRANSCRIBE_LAMBDA_NAME" ]; then
                echo "Error: TRANSCRIBE_LAMBDA_NAME not set in .env"
            else
                # Update Lambda destination bucket
                echo "Updating Lambda environment variables..."
                aws lambda update-function-configuration \
                    --function-name ${TRANSCRIBE_LAMBDA_NAME} \
                    --environment "Variables={DESTINATION_BUCKET=${S3_BUCKET}}" \
                    --region ${REGION} \
                    --profile ${PROFILE} > /dev/null
                
                # Add Lambda permission for new audio bucket
                aws lambda add-permission \
                    --function-name ${TRANSCRIBE_LAMBDA_NAME} \
                    --statement-id "${AUDIO_BUCKET}-trigger" \
                    --action "lambda:InvokeFunction" \
                    --principal s3.amazonaws.com \
                    --source-arn "arn:aws:s3:::${AUDIO_BUCKET}" \
                    --region ${REGION} \
                    --profile ${PROFILE} 2>/dev/null || echo "Permission already exists"
                
                # Configure S3 notification
                LAMBDA_ARN=$(aws lambda get-function --function-name ${TRANSCRIBE_LAMBDA_NAME} --region ${REGION} --profile ${PROFILE} --query 'Configuration.FunctionArn' --output text)
                
                cat > /tmp/notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${AUDIO_BUCKET}-trigger",
      "LambdaFunctionArn": "${LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "Suffix", "Value": ".mp3"}
          ]
        }
      }
    }
  ]
}
EOF
                
                aws s3api put-bucket-notification-configuration \
                    --bucket ${AUDIO_BUCKET} \
                    --notification-configuration file:///tmp/notification.json \
                    --region ${REGION} \
                    --profile ${PROFILE}
                
                rm /tmp/notification.json
                echo "Lambda configured: Audio=${AUDIO_BUCKET}, Output=${S3_BUCKET}"
            fi
        fi
    fi
    
    # Check if data source exists
    EXISTING_DS=$(aws bedrock-agent list-data-sources \
        --knowledge-base-id ${KB_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query "dataSourceSummaries[?name=='${PROJECT_NAME}-source'].dataSourceId" \
        --output text)
    
    if [ -n "$EXISTING_DS" ]; then
        echo "Data source already exists: ${EXISTING_DS}"
        return
    fi
    
    # Create data source
    DS_ID=$(aws bedrock-agent create-data-source \
        --knowledge-base-id ${KB_ID} \
        --name "${PROJECT_NAME}-source" \
        --data-source-configuration "type=S3,s3Configuration={bucketArn=arn:aws:s3:::${S3_BUCKET}}" \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query 'dataSource.dataSourceId' \
        --output text)
    
    echo "Created Data Source: ${DS_ID}"
    
    # Configure kb-sync Lambda for auto-sync
    if [ -n "$KB_SYNC_LAMBDA_NAME" ]; then
        read -p "Configure auto-sync for this project? (y/n): " CONFIG_SYNC
        if [[ "$CONFIG_SYNC" =~ ^[Yy]$ ]]; then
            # Update kb-sync Lambda environment
            aws lambda update-function-configuration \
                --function-name ${KB_SYNC_LAMBDA_NAME} \
                --environment "Variables={KNOWLEDGE_BASE_ID=${KB_ID},DATA_SOURCE_ID=${DS_ID}}" \
                --region ${REGION} \
                --profile ${PROFILE} > /dev/null
            
            # Add Lambda permission for main bucket
            aws lambda add-permission \
                --function-name ${KB_SYNC_LAMBDA_NAME} \
                --statement-id "${S3_BUCKET}-sync-trigger" \
                --action "lambda:InvokeFunction" \
                --principal s3.amazonaws.com \
                --source-arn "arn:aws:s3:::${S3_BUCKET}" \
                --region ${REGION} \
                --profile ${PROFILE} 2>/dev/null || echo "Permission already exists"
            
            # Configure S3 notification for auto-sync
            SYNC_LAMBDA_ARN=$(aws lambda get-function --function-name ${KB_SYNC_LAMBDA_NAME} --region ${REGION} --profile ${PROFILE} --query 'Configuration.FunctionArn' --output text)
            
            cat > /tmp/sync-notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${S3_BUCKET}-sync-trigger",
      "LambdaFunctionArn": "${SYNC_LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "Suffix", "Value": ".txt"}
          ]
        }
      }
    }
  ]
}
EOF
            
            aws s3api put-bucket-notification-configuration \
                --bucket ${S3_BUCKET} \
                --notification-configuration file:///tmp/sync-notification.json \
                --region ${REGION} \
                --profile ${PROFILE}
            
            rm /tmp/sync-notification.json
            echo "Auto-sync configured for ${S3_BUCKET}"
        fi
    fi
    
    # Start ingestion
    aws bedrock-agent start-ingestion-job \
        --knowledge-base-id ${KB_ID} \
        --data-source-id ${DS_ID} \
        --region ${REGION} \
        --profile ${PROFILE} > /dev/null
    
    echo "Project created successfully"
}

switch_project() {
    PROJECT_NAME=$(list_projects | fzf --prompt="Select project: " --height=40%)
    
    if [ -z "$PROJECT_NAME" ]; then
        echo "No project selected"
        return
    fi
    
    DS_ID=$(aws bedrock-agent list-data-sources \
        --knowledge-base-id ${KB_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query "dataSourceSummaries[?contains(name,'${PROJECT_NAME}')].dataSourceId" \
        --output text)
    
    if [ -z "$DS_ID" ]; then
        echo "Error: Project not found"
        return
    fi
    
    # Get S3 bucket from data source
    S3_BUCKET=$(aws bedrock-agent get-data-source \
        --knowledge-base-id ${KB_ID} \
        --data-source-id ${DS_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query 'dataSource.dataSourceConfiguration.s3Configuration.bucketArn' \
        --output text | sed 's/.*::://')
    
    echo "Switching to: ${PROJECT_NAME}"
    
    # Configure kb-sync Lambda for auto-sync
    if [ -n "$KB_SYNC_LAMBDA_NAME" ]; then
        read -p "Configure auto-sync for this project? (y/n): " CONFIG_SYNC
        if [[ "$CONFIG_SYNC" =~ ^[Yy]$ ]]; then
            # Update kb-sync Lambda environment
            aws lambda update-function-configuration \
                --function-name ${KB_SYNC_LAMBDA_NAME} \
                --environment "Variables={KNOWLEDGE_BASE_ID=${KB_ID},DATA_SOURCE_ID=${DS_ID}}" \
                --region ${REGION} \
                --profile ${PROFILE} > /dev/null
            
            # Add Lambda permission for main bucket
            aws lambda add-permission \
                --function-name ${KB_SYNC_LAMBDA_NAME} \
                --statement-id "${S3_BUCKET}-sync-trigger" \
                --action "lambda:InvokeFunction" \
                --principal s3.amazonaws.com \
                --source-arn "arn:aws:s3:::${S3_BUCKET}" \
                --region ${REGION} \
                --profile ${PROFILE} 2>/dev/null || echo "Permission already exists"
            
            # Configure S3 notification for auto-sync
            SYNC_LAMBDA_ARN=$(aws lambda get-function --function-name ${KB_SYNC_LAMBDA_NAME} --region ${REGION} --profile ${PROFILE} --query 'Configuration.FunctionArn' --output text)
            
            cat > /tmp/sync-notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${S3_BUCKET}-sync-trigger",
      "LambdaFunctionArn": "${SYNC_LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "Suffix", "Value": ".txt"}
          ]
        }
      }
    }
  ]
}
EOF
            
            aws s3api put-bucket-notification-configuration \
                --bucket ${S3_BUCKET} \
                --notification-configuration file:///tmp/sync-notification.json \
                --region ${REGION} \
                --profile ${PROFILE}
            
            rm /tmp/sync-notification.json
            echo "Auto-sync configured for ${S3_BUCKET}"
        fi
    fi
    
    JOB_ID=$(aws bedrock-agent start-ingestion-job \
        --knowledge-base-id ${KB_ID} \
        --data-source-id ${DS_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query 'ingestionJob.ingestionJobId' \
        --output text)
    
    echo "Ingestion Job: ${JOB_ID}"
    
    # Check if audio bucket exists and update Lambda
    AUDIO_BUCKET="audio-${S3_BUCKET}"
    if aws s3 ls "s3://${AUDIO_BUCKET}" --region ${REGION} --profile ${PROFILE} 2>/dev/null; then
        read -p "Update Lambda and S3 trigger for this project? (y/n): " UPDATE_LAMBDA
        if [[ "$UPDATE_LAMBDA" =~ ^[Yy]$ ]]; then
            if [ -z "$TRANSCRIBE_LAMBDA_NAME" ]; then
                echo "Error: TRANSCRIBE_LAMBDA_NAME not set in .env"
            else
                # Update Lambda destination bucket
                echo "Updating Lambda: Audio=${AUDIO_BUCKET}, Output=${S3_BUCKET}"
                aws lambda update-function-configuration \
                    --function-name ${TRANSCRIBE_LAMBDA_NAME} \
                    --environment "Variables={DESTINATION_BUCKET=${S3_BUCKET}}" \
                    --region ${REGION} \
                    --profile ${PROFILE} > /dev/null
                
                # Add Lambda permission for audio bucket
                aws lambda add-permission \
                    --function-name ${TRANSCRIBE_LAMBDA_NAME} \
                    --statement-id "${AUDIO_BUCKET}-trigger" \
                    --action "lambda:InvokeFunction" \
                    --principal s3.amazonaws.com \
                    --source-arn "arn:aws:s3:::${AUDIO_BUCKET}" \
                    --region ${REGION} \
                    --profile ${PROFILE} 2>/dev/null || echo "Permission already exists"
                
                # Configure S3 notification
                LAMBDA_ARN=$(aws lambda get-function --function-name ${TRANSCRIBE_LAMBDA_NAME} --region ${REGION} --profile ${PROFILE} --query 'Configuration.FunctionArn' --output text)
                
                cat > /tmp/notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${AUDIO_BUCKET}-trigger",
      "LambdaFunctionArn": "${LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "Suffix", "Value": ".mp3"}
          ]
        }
      }
    }
  ]
}
EOF
                
                aws s3api put-bucket-notification-configuration \
                    --bucket ${AUDIO_BUCKET} \
                    --notification-configuration file:///tmp/notification.json \
                    --region ${REGION} \
                    --profile ${PROFILE}
                
                rm /tmp/notification.json
                echo "Lambda updated successfully"
            fi
        fi
    fi
    
    echo "Project switched successfully"
}

update_instructions() {
    INSTRUCTIONS_DIR="${SCRIPT_DIR}/instruction-files"
    
    if [ ! -d "$INSTRUCTIONS_DIR" ]; then
        echo "Error: instruction-files directory not found"
        return
    fi
    
    INSTRUCTION_FILE=$(ls -1 ${INSTRUCTIONS_DIR}/*.md 2>/dev/null | xargs -n 1 basename | fzf --prompt="Select instruction file: " --height=40%)
    
    if [ -z "$INSTRUCTION_FILE" ]; then
        echo "No file selected"
        return
    fi
    
    PROJECT_NAME="${INSTRUCTION_FILE%.md}"
    INSTRUCTIONS=$(cat "${INSTRUCTIONS_DIR}/${INSTRUCTION_FILE}")
    
    echo "Updating agent with ${PROJECT_NAME} instructions..."
    aws bedrock-agent update-agent \
        --agent-id ${AGENT_ID} \
        --agent-name "${AGENT_NAME}" \
        --description "Agent for ${PROJECT_NAME}" \
        --instruction "${INSTRUCTIONS}" \
        --agent-resource-role-arn "${AGENT_ROLE_ARN}" \
        --foundation-model "${FOUNDATION_MODEL}" \
        --region ${REGION} \
        --profile ${PROFILE} \
        --no-cli-pager > /dev/null
    
    echo "Agent updated successfully"
}

list_projects_table() {
    aws bedrock-agent list-data-sources \
        --knowledge-base-id ${KB_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query 'dataSourceSummaries[*].[name,dataSourceId]' \
        --output table \
        --no-cli-pager
}

# Main loop
while true; do
    ACTION=$(show_menu | fzf --prompt="Select action: " --height=40%)
    
    case "$ACTION" in
        "Create New Project")
            create_project
            ;;
        "Switch Project")
            switch_project
            ;;
        "Update Agent Instructions")
            update_instructions
            ;;
        "List Projects")
            list_projects_table
            ;;
        "Exit"|"")
            echo "Goodbye"
            exit 0
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
done
