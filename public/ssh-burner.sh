#!/bin/bash
# Minimal SSH Burner - Create temporary SSH users for tunneling

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

if [ $# -lt 3 ]; then
  echo "Usage: $0 <username> <password> <days_valid>"
  echo "Example: $0 testuser testpass 7"
  exit 1
fi

USERNAME=$1
PASSWORD=$2
DAYS=$3

# Calculate expiration date exactly as useradd requires (YYYY-MM-DD)
EXPDATE=$(date -d "+${DAYS} days" +"%Y-%m-%d")

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
    echo "Error: User '$USERNAME' already exists!"
    exit 1
fi

# Create user (-e = expiry, -M = no home directory, -s = no shell access/only tunneling)
useradd -e "$EXPDATE" -M -s /bin/false "$USERNAME"

# Set password
echo "${USERNAME}:${PASSWORD}" | chpasswd

# Clear cleartext variables just in case
history -c 2>/dev/null || true

echo ""
echo "✅ SSH Account Created Successfully"
echo "======================================="
echo "  Username     : $USERNAME"
echo "  Password     : $PASSWORD"
echo "  Valid for    : $DAYS Days"
echo "  Expires on   : $EXPDATE"
echo "======================================="
