#!/bin/bash

# Containerization Installation Script for macOS
# Copyright © 2025 Apple Inc. and the Containerization project authors.

set -e

# Installation configuration
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_DIR="${INSTALL_PREFIX}/lib/containerization"
SHARE_DIR="${INSTALL_PREFIX}/share/containerization"
DOC_DIR="${INSTALL_PREFIX}/share/doc/containerization"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if running as root for system installation
check_permissions() {
    if [[ "$INSTALL_PREFIX" == "/usr/local" ]] && [[ $EUID -ne 0 ]]; then
        log_warning "Installing to /usr/local requires sudo privileges"
        log_info "You may be prompted for your password"
        return 1
    fi
    return 0
}

# Create installation directories
create_directories() {
    log_info "Creating installation directories..."
    
    if ! check_permissions; then
        sudo mkdir -p "$BIN_DIR" "$LIB_DIR" "$SHARE_DIR" "$DOC_DIR"
    else
        mkdir -p "$BIN_DIR" "$LIB_DIR" "$SHARE_DIR" "$DOC_DIR"
    fi
    
    log_success "Directories created: $BIN_DIR, $LIB_DIR, $SHARE_DIR, $DOC_DIR"
}

# Install binaries
install_binaries() {
    log_info "Installing containerization binaries..."
    
    # Check if binaries exist
    if [[ ! -f "bin/cctl" ]]; then
        log_error "cctl binary not found. Run 'make all' first."
        exit 1
    fi
    
    if [[ ! -f "bin/containerization-integration" ]]; then
        log_error "containerization-integration binary not found. Run 'make all' first."
        exit 1
    fi
    
    # Install binaries
    if ! check_permissions; then
        sudo cp "bin/cctl" "$BIN_DIR/"
        sudo cp "bin/containerization-integration" "$BIN_DIR/"
        sudo chmod +x "$BIN_DIR/cctl" "$BIN_DIR/containerization-integration"
    else
        cp "bin/cctl" "$BIN_DIR/"
        cp "bin/containerization-integration" "$BIN_DIR/"
        chmod +x "$BIN_DIR/cctl" "$BIN_DIR/containerization-integration"
    fi
    
    log_success "Binaries installed to $BIN_DIR"
}

# Install support files
install_support_files() {
    log_info "Installing support files..."
    
    # Install kernel if it exists
    if [[ -f "bin/vmlinux" ]]; then
        if ! check_permissions; then
            sudo cp "bin/vmlinux" "$SHARE_DIR/"
        else
            cp "bin/vmlinux" "$SHARE_DIR/"
        fi
        log_success "Kernel installed to $SHARE_DIR/vmlinux"
    else
        log_warning "No kernel found. You can fetch one with: make fetch-default-kernel"
    fi
    
    # Install init filesystem if it exists
    if [[ -f "bin/init.rootfs.tar.gz" ]]; then
        if ! check_permissions; then
            sudo cp "bin/init.rootfs.tar.gz" "$SHARE_DIR/"
        else
            cp "bin/init.rootfs.tar.gz" "$SHARE_DIR/"
        fi
        log_success "Init filesystem installed to $SHARE_DIR/init.rootfs.tar.gz"
    fi
    
    # Install documentation
    if ! check_permissions; then
        sudo cp README.md "$DOC_DIR/" 2>/dev/null || true
        sudo cp LICENSE "$DOC_DIR/" 2>/dev/null || true
        sudo cp -r kernel/README.md "$DOC_DIR/kernel-README.md" 2>/dev/null || true
    else
        cp README.md "$DOC_DIR/" 2>/dev/null || true
        cp LICENSE "$DOC_DIR/" 2>/dev/null || true
        cp kernel/README.md "$DOC_DIR/kernel-README.md" 2>/dev/null || true
    fi
    
    log_success "Documentation installed to $DOC_DIR"
}

# Configure environment
configure_environment() {
    log_info "Configuring environment..."
    
    # Check if BIN_DIR is in PATH
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        log_warning "$BIN_DIR is not in your PATH"
        
        # Detect shell and add to appropriate config file
        case "$SHELL" in
            */zsh)
                shell_config="$HOME/.zshrc"
                log_info "Adding $BIN_DIR to PATH in $shell_config"
                echo "" >> "$shell_config"
                echo "# Added by containerization installer" >> "$shell_config"
                echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$shell_config"
                ;;
            */bash)
                shell_config="$HOME/.bash_profile"
                log_info "Adding $BIN_DIR to PATH in $shell_config"
                echo "" >> "$shell_config"
                echo "# Added by containerization installer" >> "$shell_config"
                echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$shell_config"
                ;;
            *)
                log_warning "Unknown shell: $SHELL"
                log_info "Please manually add $BIN_DIR to your PATH"
                ;;
        esac
    else
        log_success "$BIN_DIR is already in your PATH"
    fi
    
    # Set up environment variables for containerization
    case "$SHELL" in
        */zsh)
            shell_config="$HOME/.zshrc"
            echo "export CONTAINERIZATION_KERNEL_PATH=\"$SHARE_DIR/vmlinux\"" >> "$shell_config"
            echo "export CONTAINERIZATION_INIT_PATH=\"$SHARE_DIR/init.rootfs.tar.gz\"" >> "$shell_config"
            ;;
        */bash)
            shell_config="$HOME/.bash_profile"
            echo "export CONTAINERIZATION_KERNEL_PATH=\"$SHARE_DIR/vmlinux\"" >> "$shell_config"
            echo "export CONTAINERIZATION_INIT_PATH=\"$SHARE_DIR/init.rootfs.tar.gz\"" >> "$shell_config"
            ;;
    esac
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Test cctl
    if command -v cctl >/dev/null 2>&1; then
        version=$(cctl --version 2>/dev/null || echo "unknown")
        log_success "cctl installed successfully (version: $version)"
    else
        log_error "cctl not found in PATH. You may need to restart your terminal."
        return 1
    fi
    
    # Test containerization-integration
    if command -v containerization-integration >/dev/null 2>&1; then
        log_success "containerization-integration installed successfully"
    else
        log_warning "containerization-integration not found in PATH"
    fi
    
    # Check support files
    if [[ -f "$SHARE_DIR/vmlinux" ]]; then
        log_success "Kernel available at $SHARE_DIR/vmlinux"
    else
        log_warning "No kernel installed. Run 'make fetch-default-kernel' and reinstall"
    fi
    
    return 0
}

# Create uninstall script
create_uninstaller() {
    log_info "Creating uninstall script..."
    
    cat > "$SHARE_DIR/uninstall.sh" << 'EOF'
#!/bin/bash
# Containerization Uninstaller

set -e

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_DIR="${INSTALL_PREFIX}/lib/containerization"
SHARE_DIR="${INSTALL_PREFIX}/share/containerization"
DOC_DIR="${INSTALL_PREFIX}/share/doc/containerization"

echo "🗑️  Uninstalling Containerization..."

# Remove binaries
sudo rm -f "$BIN_DIR/cctl" "$BIN_DIR/containerization-integration"

# Remove directories
sudo rm -rf "$LIB_DIR" "$SHARE_DIR" "$DOC_DIR"

echo "✅ Containerization uninstalled successfully"
echo "Note: PATH modifications in shell config files were not removed automatically"
EOF

    if ! check_permissions; then
        sudo chmod +x "$SHARE_DIR/uninstall.sh"
    else
        chmod +x "$SHARE_DIR/uninstall.sh"
    fi
    
    log_success "Uninstaller created at $SHARE_DIR/uninstall.sh"
}

# Main installation process
main() {
    echo "🚀 Containerization Installation Script"
    echo "======================================"
    echo ""
    echo "Installing to: $INSTALL_PREFIX"
    echo ""
    
    # Check if we're in the right directory
    if [[ ! -f "Package.swift" ]] || [[ ! -d "Sources/Containerization" ]]; then
        log_error "Please run this script from the containerization project root directory"
        exit 1
    fi
    
    # Check if project is built
    if [[ ! -f "bin/cctl" ]]; then
        log_error "Project not built. Please run 'make all' first"
        exit 1
    fi
    
    # Perform installation
    create_directories
    install_binaries
    install_support_files
    configure_environment
    create_uninstaller
    
    if verify_installation; then
        echo ""
        echo "🎉 Installation completed successfully!"
        echo ""
        echo "📋 Summary:"
        echo "   • Binaries installed to: $BIN_DIR"
        echo "   • Support files installed to: $SHARE_DIR"
        echo "   • Documentation installed to: $DOC_DIR"
        echo ""
        echo "🔧 Usage:"
        echo "   • Run 'cctl --help' to get started"
        echo "   • Example: cctl run --kernel $SHARE_DIR/vmlinux --ip 192.168.64.10/24"
        echo ""
        echo "🗑️  To uninstall: $SHARE_DIR/uninstall.sh"
        echo ""
        echo "⚠️  Please restart your terminal or run 'source ~/.zshrc' to update your PATH"
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

# Parse command line arguments
case "${1:-}" in
    --help|-h)
        echo "Containerization Installation Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --prefix PATH    Installation prefix (default: /usr/local)"
        echo "  --user          Install to user directory (~/.local)"
        echo "  --help          Show this help"
        echo ""
        echo "Environment Variables:"
        echo "  INSTALL_PREFIX   Override installation prefix"
        exit 0
        ;;
    --user)
        INSTALL_PREFIX="$HOME/.local"
        BIN_DIR="$INSTALL_PREFIX/bin"
        LIB_DIR="$INSTALL_PREFIX/lib/containerization"
        SHARE_DIR="$INSTALL_PREFIX/share/containerization"
        DOC_DIR="$INSTALL_PREFIX/share/doc/containerization"
        ;;
    --prefix)
        if [[ -z "${2:-}" ]]; then
            log_error "--prefix requires a path argument"
            exit 1
        fi
        INSTALL_PREFIX="$2"
        BIN_DIR="$INSTALL_PREFIX/bin"
        LIB_DIR="$INSTALL_PREFIX/lib/containerization"
        SHARE_DIR="$INSTALL_PREFIX/share/containerization"
        DOC_DIR="$INSTALL_PREFIX/share/doc/containerization"
        shift
        ;;
    --prefix=*)
        INSTALL_PREFIX="${1#--prefix=}"
        BIN_DIR="$INSTALL_PREFIX/bin"
        LIB_DIR="$INSTALL_PREFIX/lib/containerization"
        SHARE_DIR="$INSTALL_PREFIX/share/containerization"
        DOC_DIR="$INSTALL_PREFIX/share/doc/containerization"
        ;;
esac

# Run main installation
main "$@"