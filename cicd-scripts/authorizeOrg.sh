#!/bin/bash
openssl enc -nosalt -aes-256-cbc -d -in assets/server.key.enc -out assets/server.key -base64 -K $DECRYPTION_KEY -iv $DECRYPTION_IV
sf auth jwt grant --client-id $CONSUMERKEY --jwt-key-file assets/server.key --username $USERNAME --instance-url https://efficiency-business-389-dev-ed.scratch.my.salesforce.com/ -a $TARGETORG
