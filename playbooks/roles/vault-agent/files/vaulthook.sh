#!/bin/bash
export VAULT_ADDR="http://127.0.0.1:8100"
command=$1
shift 1
text=$@

if [ $command == "encrypt" ]; then
        result=$(vault write transit/encrypt/webapp-key plaintext=$(base64 <<< $text) -format=json | jq -r '.data.ciphertext')
elif [ $command == "decrypt" ]; then
        result=$(vault write transit/decrypt/webapp-key ciphertext=$text -format=json | jq -r '.data.plaintext' | base64 -d)
fi
echo $result