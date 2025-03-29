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
REMOVE_UNFORKED_BACKUPS=false       # Set to "true" to remove backups for repositories that are no longer forked, "false" to keep them
VERBOSE=false                       # Set to "true" for detailed output, "false" for minimal output (this is used for debugging)
LOG_PATH="/var/logs"                         # If non-empty, log messages will be written to this file (e.g., "/path/to/script.log")
LOG_MAX_SIZE_MB=10                  # Maximum log file size (in MB) before rotation occurs
MAX_LOG_ZIPS=3                      # Maximum number of rotated (zipped) logs to keep

mkdir -p "${BACKUP_DIR}"
shopt -s nullglob
NOW=$(date +"%Y%m%d_%H%M%S")
START_TIME=$(date +%s)
START_SIZE=$(du -sb "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo 0)

if [ -n "${LOG_PATH}" ]; then
    if [[ "$LOG_PATH" != */BackupForks.log ]]; then
        LOG_FILE="${LOG_PATH%/}/BackupForks.log"
    else
        LOG_FILE="$LOG_PATH"
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
else
    LOG_FILE=""
fi

# Helper function: log rotation
rotate_log_if_needed() {
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        local max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
        local filesize
        filesize=$(stat -c%s "$LOG_FILE")
        if [ "$filesize" -ge "$max_bytes" ]; then
            local ts
            ts=$(date +"%Y%m%d_%H%M%S")
            local rotated_log="${LOG_FILE}_${ts}.tar.gz"
            # Compress the log file using tar with gzip compression
            tar -czf "$rotated_log" -C "$(dirname "$LOG_FILE")" "$(basename "$LOG_FILE")"
            # Clear the current log file
            : > "$LOG_FILE"
            # Remove old rotated logs if more than MAX_LOG_ZIPS exist
            local rotated_files
            mapfile -t rotated_files < <(ls -1tr "${LOG_FILE}"_*.tar.gz 2>/dev/null || true)
            local count=${#rotated_files[@]}
            if [ "$count" -gt "$MAX_LOG_ZIPS" ]; then
                local num_to_delete=$(( count - MAX_LOG_ZIPS ))
                for old_log in $(ls -1tr "${LOG_FILE}"_*.tar.gz | head -n "$num_to_delete"); do
                    rm -f "$old_log"
                done
            fi
        fi
    fi
}

# Helper function: log messages with different log levels
log_to_file() {
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") $1" >> "$LOG_FILE"
    fi
}
log_info() {
    local message="[INFO] $*"
    echo "$message" >&2
    log_to_file "$message"
}
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        local message="[VERBOSE] $*"
        echo "$message" >&2
        log_to_file "$message"
    fi
}
log_warn() {
    local message="[WARN] $*"
    echo "$message" >&2
    log_to_file "$message"
}
log_error() {
    local message="[ERROR] $*"
    echo "$message" >&2
    log_to_file "$message"
}

# Helper function: makes a GitHub API call, captures rate-limit headers, and sleeps if we are near or at the limit.
call_github_api() {
    local method="$1"      # e.g., GET, POST, PATCH, etc.
    local url="$2"
    local data="${3:-}"    # JSON body if needed, otherwise empty

    local temp_headers
    local temp_body
    temp_headers=$(mktemp)
    temp_body=$(mktemp)

    log_verbose "Making $method request to $url"
    [ -n "$data" ] && log_verbose "Request body: $data"

    curl -s -D "$temp_headers" -X "$method" \
         -H "Authorization: token ${GITHUB_TOKEN}" \
         -H "Content-Type: application/json" \
         ${data:+ -d "$data"} \
         "$url" > "$temp_body"

    # Extract rate-limit info from headers
    local remaining
    local reset
    remaining=$(grep -i '^X-RateLimit-Remaining:' "$temp_headers" | awk '{print $2}' | tr -d '\r')
    reset=$(grep -i '^X-RateLimit-Reset:' "$temp_headers" | awk '{print $2}' | tr -d '\r')
    log_verbose "X-RateLimit-Remaining: $remaining"
    log_verbose "X-RateLimit-Reset:     $reset"

    # Check if near or at the rate limit, if less than or equal to 5, sleep until reset time.
    if [ -n "$remaining" ] && [ -n "$reset" ]; then
        if [ "$remaining" -le 5 ]; then
            local current_time
            current_time=$(date +%s)
            local sleep_duration=$(( reset - current_time ))
            if [ "$sleep_duration" -gt 0 ]; then
                log_warn "Rate limit reached or nearly reached. Sleeping for $sleep_duration seconds..."
                sleep "$sleep_duration"
            fi
        fi
    fi

    cat "$temp_body"
    rm -f "$temp_headers" "$temp_body"
}

# Helper function: convert bytes to human-readable size
human_readable_size() {
    local bytes=$1

    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt $((1024 * 1024)) ]; then
        # Convert bytes to KB
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    elif [ "$bytes" -lt $((1024 * 1024 * 1024)) ]; then
        # Convert bytes to MB
        awk "BEGIN {printf \"%.2f MB\", $bytes/(1024*1024)}"
    else
        # Convert bytes to GB
        awk "BEGIN {printf \"%.2f GB\", $bytes/(1024*1024*1024)}"
    fi
}

forks_processed=0
forks_updated=0
backups_created=0
backups_deleted=0

######################################
# Main script logic
######################################

if [ -n "${LOG_FILE:-}" ]; then
    rotate_log_if_needed
fi

log_verbose "Fetching forked repositories for organization: ${GITHUB_ORG}"

# Get all forked repos along with their default branch
FORKED_REPOS=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/orgs/${GITHUB_ORG}/repos?per_page=100" | \
    jq -r '.[] | select(.fork==true) | "\(.name) \(.default_branch)"')

if [ -z "$FORKED_REPOS" ]; then
    echo "No forked repositories found in ${GITHUB_ORG}."
    exit 0
fi

# Create an array of just the repo names (no default branch)
mapfile -t FORKED_REPO_NAMES < <(echo "$FORKED_REPOS" | awk '{print $1}')
log_verbose "Found ${#FORKED_REPO_NAMES[@]} forked repository(ies) in organization."

# Loop through each forked repo to update, backup (if needed), and update its description
while read -r repo default_branch; do
    forks_processed=$((forks_processed + 1))
    log_verbose "----------------------------------------"
    log_verbose "Processing repository: ${repo}"
    log_verbose "Default branch: ${default_branch}"

    log_info "Updating fork for ${repo}..."
    update_response=$(call_github_api "POST" \
        "https://api.github.com/repos/${GITHUB_ORG}/${repo}/merge-upstream" \
        "{\"branch\": \"${default_branch}\"}")

    log_verbose "Fork update response for ${repo}: ${update_response}"

    # Get the merge_type from the response (if any)
    merge_type=$(echo "$update_response" | jq -r '.merge_type // empty')
    if [ "$merge_type" = "fast-forward" ]; then
        forks_updated=$((forks_updated + 1))
        log_verbose "Repo ${repo} had new commits. (merge_type: fast-forward)"
    else
        log_verbose "Repo ${repo} had no new commits. (merge_type: $merge_type)"
    fi

    # Count existing backups for this repo using globbing
    backup_files=("${BACKUP_DIR}/${repo}"_*.zip)
    existing_backup_count=${#backup_files[@]}
    log_verbose "Found $existing_backup_count existing backup(s) for repo: ${repo}"

    need_backup=false
    if [ "$CHECK_FOR_CHANGES" = true ]; then
        # Only backup if new changes were merged OR no backup exists locally
        if [ "$merge_type" == "fast-forward" ] || [ "$existing_backup_count" -eq 0 ]; then
            need_backup=true
        fi
    else
        need_backup=true
    fi

    # Create the backup (zip archive) for the default branch
    if [ "$need_backup" = true ]; then
        log_info "Creating backup for ${repo}..."
        zip_url="https://api.github.com/repos/${GITHUB_ORG}/${repo}/zipball/${default_branch}"
        backup_file="${BACKUP_DIR}/${repo}_${NOW}.zip"

        curl -L -s -H "Authorization: token ${GITHUB_TOKEN}" -o "${backup_file}" "${zip_url}"
        log_info "Backup created: ${backup_file}"
        backups_created=$((backups_created + 1))
    else
        log_info "No backup created for ${repo}."
    fi

    # Remove old backups if exceeding MAX_BACKUPS
    backup_files=("${BACKUP_DIR}/${repo}"_*.zip)
    backup_count=${#backup_files[@]}
    if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
        log_verbose "Cleaning up old backups for ${repo}..."
        # Remove the oldest backups first
        files_to_remove=$(ls -1tr "${BACKUP_DIR}/${repo}"_*.zip | head -n $((backup_count - MAX_BACKUPS)))
        for old_file in $files_to_remove; do
            rm "$old_file"
            log_verbose "Removed old backup: ${old_file}"
            backups_deleted=$((backups_deleted + 1))
        done
    fi

    # Update the repository description with the latest sync time
    LAST_SYNC=$(date +"%Y-%m-%d %H:%M:%S")
    NEW_DESCRIPTION="This repository is automatically synced with the original repository. Last sync: ${LAST_SYNC}"
    log_verbose "Updating description for ${repo}: ${NEW_DESCRIPTION}"
    json_payload=$(jq -n --arg desc "$NEW_DESCRIPTION" '{description: $desc}')

    update_desc_response=$(call_github_api "PATCH" \
        "https://api.github.com/repos/${GITHUB_ORG}/${repo}" \
        "$json_payload")

    log_verbose "Update repository description response for ${repo}: ${update_desc_response}"

done <<< "$FORKED_REPOS"

# Remove backups for repositories that are no longer forked
if [ "${REMOVE_UNFORKED_BACKUPS}" = "true" ]; then
    log_info "Removing backups for repos that are no longer forks..."

    for backup_file in "${BACKUP_DIR}"/*.zip; do
        [ -e "$backup_file" ] || break  # no .zip files exist
        base="$(basename "$backup_file")"

        # Use grep -E to match the pattern, and sed to remove the _YYYYmmdd_HHMMSS.zip
        # If the file doesn't match the pattern, repo_name might be empty.
        # Example file: myrepo_20230305_090101.zip -> "myrepo"
        matched="$(echo "$base" | grep -E '^[^_]+_[0-9]{8}_[0-9]{6}\.zip$' || true)"
        if [ -n "$matched" ]; then
            # Remove the underscore + timestamp + ".zip" from the end to get the base repo name
            repo_name="$(echo "$base" | sed -E 's/_[0-9]{8}_[0-9]{6}\.zip$//')"
        else
            # This means the file does not match the expected naming pattern
            log_verbose "Skipping $backup_file; pattern not matched."
            continue
        fi

        # Check if the extracted repo_name is still in the list of current forked repos
        if ! printf '%s\n' "${FORKED_REPO_NAMES[@]}" | grep -qxF "$repo_name"; then
            log_info "Removing backup for '$repo_name' (no longer a fork): $backup_file"
            rm -f "$backup_file"
            backups_deleted=$((backups_deleted + 1))
        fi
    done
else
    log_verbose "REMOVE_UNFORKED_BACKUPS is disabled; not removing backups for repos that are no longer forks."
fi

END_TIME=$(date +%s)
END_SIZE=$(du -sb "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo 0)
DURATION=$(( END_TIME - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))
DURATION_MMSS=$(printf "%02d:%02d" "$MINUTES" "$SECONDS")
SIZE_DIFF=$(( END_SIZE - START_SIZE ))
SIZE_DIFF_HUMAN=$(human_readable_size "$SIZE_DIFF")
if [ "$SIZE_DIFF" -gt 0 ]; then
    SIZE_DIFF_FORMAT="+${SIZE_DIFF_HUMAN}"
elif [ "$SIZE_DIFF" -lt 0 ]; then
    POSITIVE_SIZE=$((0 - SIZE_DIFF))
    SIZE_DIFF_HUMAN=$(human_readable_size "$POSITIVE_SIZE")
    SIZE_DIFF_FORMAT="-${SIZE_DIFF_HUMAN}"
else
    SIZE_DIFF_FORMAT="0 bytes (no change)"
fi

log_info "Backup process completed."
log_info "----------------------------------------"
log_info "Summary:"
log_info "  * Forks processed:   $forks_processed"
log_info "  * Forks updated:     $forks_updated"
log_info "  * Backups created:   $backups_created"
log_info "  * Backups deleted:   $backups_deleted"
log_info "  * Duration:          ${DURATION_MMSS}"
log_info "----------------------------------------"
log_info "Storage:"
log_info "  * Backup directory:  $BACKUP_DIR"
log_info "  * Max backups:       $MAX_BACKUPS"
log_info "  * Disk changes:      $SIZE_DIFF_FORMAT"
log_info "----------------------------------------"

exit 0
