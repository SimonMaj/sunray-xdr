#!/bin/sh
set -eu

APP_NAME="Sunray XDR"
APP_PATH="/Applications/${APP_NAME}.app"

cd "$(dirname "$0")"

echo "Building ${APP_NAME}..."
make app

echo "Installing to ${APP_PATH}..."
rm -rf "${APP_PATH}"
ditto ".build/${APP_NAME}.app" "${APP_PATH}"
touch "${APP_PATH}"

echo "Verifying app signature..."
codesign --verify --deep --strict "${APP_PATH}"

echo "Opening ${APP_NAME}..."
open "${APP_PATH}"

echo "${APP_NAME} installed successfully."
