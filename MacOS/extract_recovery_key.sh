#!/bin/bash

# Check if FileVault is enabled
fdesetup status | grep -q "FileVault is On"

if [ $? -eq 0 ]; then
    echo "FileVault is enabled. Extracting recovery key..."
    
    # Extract the recovery key
    recovery_key=$(sudo fdesetup recoverykey -show)
    
    if [ -n "$recovery_key" ]; then
        echo "Recovery Key: $recovery_key"
    else
        echo "Error: Unable to retrieve the recovery key."
    fi
else
    echo "FileVault is not enabled on this system."
fi
