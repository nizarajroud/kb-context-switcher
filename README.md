# KB Context Switcher

Multi-tenant knowledge base manager for AWS Bedrock agents. Manages project isolation by dynamically switching between S3-backed data sources within a single knowledge base.

## Usage

```bash
./kb-context-switcher.sh
```

## Requirements

- AWS CLI configured with appropriate credentials
- `fzf` installed: `sudo apt install fzf`
- `.env` file with AWS configuration (see `.env` for details)

## Features

**Create New Project**
- Creates S3 bucket with versioning for documents
- Optional: Creates audio S3 bucket for MP3 files
- Adds bucket as data source to knowledge base
- Configures Lambda functions for transcription and auto-sync
- Starts initial document ingestion

**Switch Project**
- Fuzzy search through available projects
- Syncs selected project's data source
- Reconfigures Lambda functions for the selected project
- Makes project data active for agent queries

**Update Agent Instructions**
- Select instruction file from `instruction-files/` directory
- Updates agent DRAFT with project-specific instructions

**List Projects**
- Displays all projects with their data source IDs

## Architecture

The system uses:
- One knowledge base (configured in `.env`)
- Multiple S3-backed data sources (one per project)
- Dynamic context switching via ingestion jobs
- Two Lambda functions:
  - Transcription Lambda: Processes MP3 files from audio bucket
  - KB Sync Lambda: Auto-syncs knowledge base when new documents are added

## Workflow

1. Create project → Creates S3 buckets and data source
2. Upload MP3 files to audio bucket → Transcription Lambda triggered
3. Transcriptions saved to main bucket → KB Sync Lambda triggered
4. Knowledge base automatically syncs new content
5. Switch to project → Updates Lambda configurations
6. Query agent → Uses active project's data
