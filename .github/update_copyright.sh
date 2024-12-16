#!/bin/bash

# Define the copyright header
HEADER="# Copyright (c) 2024-$(date +%Y) Hopsworks AB. All rights reserved."

# File for tracking changes
TRACK_FILE=".header_check_changes.txt"

# Initialize the tracking file if it doesn't exist
if [ ! -f "$TRACK_FILE" ]; then
    touch "$TRACK_FILE"
fi

# Function to get the hash of a file's content
get_file_hash() {
    sha256sum "$1" | awk '{print $1}'
}

# Function to add the header after the shebang, if present, or replace existing copyright
add_header_after_shebang() {
    local file="$1"
    # Read the first line to check if it's a shebang
    first_line=$(head -n 1 "$file")

    # If it's a shebang, add the header after it and ensure one blank line follows the header
    if [[ "$first_line" =~ ^#! ]]; then
        {
            echo "$first_line"
            echo ""
            echo "$HEADER"
            echo ""
            tail -n +2 "$file" | sed '/^# Copyright (c)/d'
        } >temp && mv temp "$file"
    else
        # Otherwise, just prepend the header with a blank line
        {
            echo "$HEADER"
            echo ""
            sed '/^# Copyright (c)/d' "$file"
        } >temp && mv temp "$file"
    fi
}

# Traverse the repository and check files
find . -type f \( \
    -iname "*.yaml" -o \
    -iname "*.yml" -o \
    -iname "*.sh" -o \
    -iname "*.py" \
    \) ! -path "./values/*" ! -path "./.github/*" | while read file; do
    # Get the current file hash
    current_hash=$(get_file_hash "$file")

    # Check if the header is already present
    if ! grep -q "$HEADER" "$file"; then
        # Add the header after the shebang or at the top of the file
        add_header_after_shebang "$file"
        echo "Added header to $file"
    else
        echo "Header already present in $file"
    fi

    # Get the updated file hash after potential modification
    updated_hash=$(get_file_hash "$file")

    # Compare the original and updated hash
    if [ "$current_hash" != "$updated_hash" ]; then
        # If the hash changed, track the modified file
        echo "$file" >>"$TRACK_FILE"
    fi
done

MODIFIED_FILES=$(cat "$TRACK_FILE")
rm "$TRACK_FILE"

# Check if any files were modified and have a new header
if [ -n "$MODIFIED_FILES" ]; then
    echo -e "The following files were modified to include the copyright header:"
    echo -e "$MODIFIED_FILES"
    exit 1
else
    echo "No files needed modification."
fi
