#!/bin/sh
# 測試用的家目錄路徑產生器：輸出 {"file_path":"<HOME>/<前綴><後段>"}，測試腳本裡不留個人路徑字面值。
printf '{"file_path":"%s/%s%s"}' "$HOME" "${1:-dev/}" "${2:-x.js}"
