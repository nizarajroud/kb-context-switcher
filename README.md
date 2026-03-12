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
- Creates S3 bucket with versioning
- Adds bucket as data source to knowledge base
- Starts initial document ingestion

**Switch Project**
- Fuzzy search through available projects
- Syncs selected project's data source
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

## Workflow

1. Create project → Creates S3 bucket and data source
2. Upload documents to S3 bucket
3. Switch to project → Syncs data source
4. Query agent → Uses active project's data# kb-context-switcher
