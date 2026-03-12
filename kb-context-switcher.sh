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
    read -p "S3 bucket name: " S3_BUCKET
    
    if [ -z "$PROJECT_NAME" ] || [ -z "$S3_BUCKET" ]; then
        echo "Error: Both fields required"
        return
    fi
    
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
    
    echo "Switching to: ${PROJECT_NAME}"
    JOB_ID=$(aws bedrock-agent start-ingestion-job \
        --knowledge-base-id ${KB_ID} \
        --data-source-id ${DS_ID} \
        --region ${REGION} \
        --profile ${PROFILE} \
        --query 'ingestionJob.ingestionJobId' \
        --output text)
    
    echo "Ingestion Job: ${JOB_ID}"
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
