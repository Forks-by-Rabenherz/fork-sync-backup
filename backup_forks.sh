#!/bin/bash
set -euo pipefail

######################################
# Configuration - adjust these values:
######################################
GITHUB_ORG="your_org_here"          # Your GitHub organization name (e.g., "Forks-by-Rabenherz")
GITHUB_TOKEN="your_token_here"      # GitHub Personal Access Token with necessary permissions (Fine-grained permissions: "administration, code, commit statuses"
BACKUP_DIR="/path/to/backup_dir"    # Local directory to store backup zip files (e.g., "./backups" or "/tmp/backups")
MAX_BACKUPS=30                      # Maximum number of backups to retain per repository (older backups will be deleted)
CHECK_FOR_CHANGES=true              # Set to "true" to check for changes before taking a backup, "false" to always take a backup
VERBOSE=false                       # Set to "true" for detailed output, "false" for minimal output (this is used for debugging)

mkdir -p "${BACKUP_DIR}"
shopt -s nullglob
NOW=$(date +"%Y%m%d_%H%M%S")

[ "$VERBOSE" = true ] && echo "Fetching forked repositories for organization: ${GITHUB_ORG}"

# Get all forked repos along with their default branch
FORKED_REPOS=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/orgs/${GITHUB_ORG}/repos?per_page=100" | \
    jq -r '.[] | select(.fork==true) | "\(.name) \(.default_branch)"')

if [ -z "$FORKED_REPOS" ]; then
    echo "No forked repositories found in ${GITHUB_ORG}."
    exit 0
fi

# Loop through each forked repo to update, backup (if needed), and update its description
while read -r repo default_branch; do
    if [ "$VERBOSE" = true ]; then
        echo "----------------------------------------"
        echo "Processing repository: ${repo}"
        echo "Default branch: ${default_branch}"
    fi

    echo "Updating fork for ${repo}..."
    update_response=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"branch\": \"${default_branch}\"}" \
        "https://api.github.com/repos/${GITHUB_ORG}/${repo}/merge-upstream")
    if [ "$VERBOSE" = true ]; then
        echo "Fork update response for ${repo}: ${update_response}"
    fi

    # Get the merge_type from the response (if any)
    merge_type=$(echo "$update_response" | jq -r '.merge_type // empty')

    # Count existing backups for this repo using globbing
    backup_files=("${BACKUP_DIR}/${repo}"_*.zip)
    existing_backup_count=${#backup_files[@]}

    if [ "$CHECK_FOR_CHANGES" = true ]; then
        # Only backup if new changes were merged OR no backup exists locally
        if [ "$merge_type" == "fast-forward" ] || [ "$existing_backup_count" -eq 0 ]; then
            echo "Creating backup for ${repo}..."
        else
            echo "No new changes for ${repo} and backup already exists locally. Skipping backup."
            continue
        fi
    else
        echo "Creating backup for ${repo}..."
    fi

    # Create the backup (zip archive) for the default branch
    zip_url="https://api.github.com/repos/${GITHUB_ORG}/${repo}/zipball/${default_branch}"
    backup_file="${BACKUP_DIR}/${repo}_${NOW}.zip"
    curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" -o "${backup_file}" "${zip_url}"
    echo "Backup created: ${backup_file}"

    # Remove old backups if exceeding MAX_BACKUPS
    backup_files=("${BACKUP_DIR}/${repo}"_*.zip)
    backup_count=${#backup_files[@]}
    if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
        [ "$VERBOSE" = true ] && echo "Cleaning up old backups for ${repo}..."
        # Remove the oldest backups first
        files_to_remove=$(ls -1tr "${BACKUP_DIR}/${repo}"_*.zip | head -n $(($backup_count - MAX_BACKUPS)))
        for old_file in $files_to_remove; do
            rm "$old_file"
            [ "$VERBOSE" = true ] && echo "Removed old backup: ${old_file}"
        done
    fi

    # Update the repository description with the latest sync time
    LAST_SYNC=$(date +"%Y-%m-%d %H:%M:%S")
    NEW_DESCRIPTION="This repository is automatically synced with the original repository. Last sync: ${LAST_SYNC}"
    echo "Updating description for ${repo} with: ${NEW_DESCRIPTION}"
    json_payload=$(jq -n --arg desc "$NEW_DESCRIPTION" '{description: $desc}')
    update_desc_response=$(curl -s -X PATCH \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "https://api.github.com/repos/${GITHUB_ORG}/${repo}")
    if [ "$VERBOSE" = true ]; then
        echo "Update repository description response for ${repo}: ${update_desc_response}"
    fi

done <<< "$FORKED_REPOS"

echo "Backup process completed."
