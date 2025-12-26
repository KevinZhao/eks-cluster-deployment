#!/bin/bash
# Connect to Frankfurt bastion host via SSM
# Bastion Instance ID: i-02dce60a8f397b6ce
# Region: eu-central-1

echo "Connecting to Frankfurt bastion host..."
echo "Bastion ID: i-02dce60a8f397b6ce"
echo ""

aws ssm start-session --target i-02dce60a8f397b6ce --region eu-central-1
