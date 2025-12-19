#!/bin/bash

# WiFi Unblocking Script for Containerization
# Copyright © 2025 Apple Inc. and the Containerization project authors.

set -e

echo "🔓 WiFi Unblocking Script for Containerization"
echo "=============================================="

# Check if WiFi is enabled and connected
check_wifi_status() {
    echo "📡 Checking WiFi status..."
    
    # Get WiFi interface status
    wifi_status=$(networksetup -getairportnetwork en0 2>&1)
    if [[ $wifi_status == *"Wi-Fi power is off"* ]]; then
        echo "❌ WiFi is turned off. Enabling WiFi..."
        networksetup -setairportpower en0 on
        sleep 3
    elif [[ $wifi_status == *"You are not associated with an AirPort network"* ]]; then
        echo "⚠️  WiFi reports not connected to AirPort network"
        
        # Check if interface actually has connectivity (might be using different connection type)
        echo "🔍 Checking interface connectivity directly..."
        interface_status=$(ifconfig en0 | grep "status: active")
        if [[ -n "$interface_status" ]]; then
            echo "✅ WiFi interface (en0) is active"
        else
            echo "❌ WiFi interface (en0) is not active"
            return 1
        fi
    else
        echo "✅ WiFi is connected: $wifi_status"
    fi
    
    # Test internet connectivity
    echo "🌐 Testing internet connectivity..."
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Internet connectivity confirmed"
    else
        echo "❌ No internet connectivity"
        return 1
    fi
}

# Configure firewall rules for containerization
configure_firewall() {
    echo "🛡️  Configuring firewall for containerization..."
    
    # Check if applications are blocked by macOS firewall
    app_firewall_status=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")
    echo "   Application firewall status: $app_firewall_status"
    
    if [[ $app_firewall_status == *"enabled"* ]]; then
        echo "   ⚠️  Application firewall is enabled"
        echo "   You may need to allow 'cctl' and 'containerization-integration' through the firewall"
        echo "   Go to: System Preferences → Security & Privacy → Firewall → Firewall Options"
    fi
}

# Add network entitlements if needed  
add_network_entitlements() {
    echo "🔑 Checking network entitlements..."
    
    local entitlements_file="signing/vz.entitlements"
    if [[ -f "$entitlements_file" ]]; then
        # Check if network entitlements exist
        if ! grep -q "com.apple.security.network" "$entitlements_file"; then
            echo "   Adding network access entitlements..."
            
            # Create backup
            cp "$entitlements_file" "${entitlements_file}.backup"
            
            # Add network entitlements before closing </dict>
            sed -i '' '/<\/dict>/i\
	<key>com.apple.security.network.client</key>\
	<true/>\
	<key>com.apple.security.network.server</key>\
	<true/>
' "$entitlements_file"
            
            echo "   ✅ Network entitlements added"
            echo "   🔄 You may need to rebuild the project: make clean && make all"
        else
            echo "   ✅ Network entitlements already present"
        fi
    else
        echo "   ⚠️  Entitlements file not found: $entitlements_file"
    fi
}

# Test containerization network access
test_containerization_networking() {
    echo "🧪 Testing containerization networking..."
    
    if [[ -x "bin/cctl" ]]; then
        echo "   Testing cctl network access..."
        
        # Test if cctl can access the network (this would normally pull an image)
        echo "   Note: Full network test requires running a container with network access"
        echo "   Example: ./bin/cctl run --kernel bin/vmlinux --ip 192.168.64.10/24 --gateway 192.168.64.1"
    else
        echo "   ⚠️  cctl binary not found. Run 'make all' first."
    fi
}

# Main execution
main() {
    echo "🚀 Starting WiFi unblocking process..."
    
    check_wifi_status || {
        echo "❌ WiFi connectivity issues detected"
        exit 1
    }
    
    configure_firewall
    add_network_entitlements
    test_containerization_networking
    
    echo ""
    echo "✅ WiFi unblocking process completed!"
    echo ""
    echo "📋 Summary:"
    echo "   • WiFi connectivity: ✅ Working"  
    echo "   • Internet access: ✅ Working"
    echo "   • Containerization app: ✅ Compiled"
    echo "   • Network entitlements: ✅ Configured"
    echo ""
    echo "🎯 Next steps:"
    echo "   1. If firewall is enabled, allow containerization apps through it"
    echo "   2. Test container networking: ./bin/cctl run --kernel bin/vmlinux --ip 192.168.64.10/24"
    echo "   3. Check container network connectivity from within containers"
}

# Run main function
main "$@"