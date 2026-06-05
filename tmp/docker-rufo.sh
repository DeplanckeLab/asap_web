#!/bin/bash
# Get the file path that needs formatting
FILE_PATH=$1

# Run rufo inside the Docker container
# Replace 'your-container-name' with your actual container name
docker exec your-container-name rufo "$FILE_PATH" 