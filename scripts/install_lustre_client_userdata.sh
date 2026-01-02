#!/bin/bash

# This script generates user data for EKS nodes to install Lustre client
# Usage: Add this to your node group's Launch Template user data

cat <<'EOF'
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
set -ex

# Install Lustre client on Amazon Linux 2023 EKS nodes
echo "Installing Lustre client..."

# Get kernel version
KERNEL_VERSION=$(uname -r)
echo "Kernel version: $KERNEL_VERSION"

# Both Amazon Linux 2 and 2023 support FSx Lustre client
# AL2023 requires kernel 6.1.79+ or 6.12+ for Lustre 2.15

# Check OS version
if grep -q "Amazon Linux 2023" /etc/os-release; then
    echo "Installing Lustre client on Amazon Linux 2023..."

    # Install Lustre client for AL2023
    dnf install -y lustre-client

    # Load Lustre module
    modprobe lustre

    # Verify installation
    if lsmod | grep -q lustre; then
        echo "✓ Lustre client installed successfully on AL2023"
        modinfo lustre | grep version
    else
        echo "✗ Lustre module not loaded"
        exit 1
    fi

elif grep -q "Amazon Linux 2" /etc/os-release; then
    # Amazon Linux 2 has better Lustre support
    echo "Installing Lustre client on Amazon Linux 2..."

    # Install Lustre client
    amazon-linux-extras install -y lustre

    # Load Lustre module
    modprobe lustre

    # Verify installation
    if lsmod | grep -q lustre; then
        echo "✓ Lustre client installed successfully"
    else
        echo "✗ Lustre module not loaded"
        exit 1
    fi
fi

--==BOUNDARY==--
EOF
