#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

CONFIG="$1"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" && "$CONFIG" != "" ]]; then
    echo "Usage: $0 [debug|release]"
    echo "  debug   - Build Debug configuration only"
    echo "  release - Build Release configuration only" 
    echo "  (empty) - Build both Debug and Release configurations"
    exit 1
fi

echo "Starting Sparkle build process..."

echo "Checking git submodules..."
git submodule update --init --recursive
if [ $? -ne 0 ]; then
    echo "Error: Failed to update git submodules"
    exit 1
fi

echo "Cleaning output and build directories..."
rm -rf output/
rm -rf build/
mkdir -p output/debug
mkdir -p output/release

build_configuration() {
    local config=$1
    local config_lower=$(echo "$config" | tr '[:upper:]' '[:lower:]')
    
    echo "Building $config configuration..."
    
    xcodebuild clean build \
        -scheme Sparkle \
        -configuration "$config" \
        -arch arm64 \
        -derivedDataPath ./build
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to build $config configuration"
        exit 1
    fi
    
    echo "Copying $config output to output/$config_lower/"
    cp -r "./build/Build/Products/$config/Sparkle.framework" "./output/$config_lower/"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy $config output"
        exit 1
    fi
    
    echo "$config build completed successfully"
}

if [[ "$CONFIG" == "debug" ]]; then
    build_configuration "Debug"
elif [[ "$CONFIG" == "release" ]]; then
    build_configuration "Release"
else
    build_configuration "Debug"
    build_configuration "Release"
fi

echo "Build process completed successfully!"
echo "Output structure:"
ls -la output/