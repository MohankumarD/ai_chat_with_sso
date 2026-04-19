#!/bin/sh

# Wait for Keycloak to be ready
echo "Waiting for Keycloak to be ready..."
i=0
while [ $i -lt 60 ]; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://keycloak:8080/realms/master 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Keycloak is ready"
    break
  fi
  i=$((i+1))
  echo "Attempt $i/60: Waiting for Keycloak (HTTP $HTTP_CODE)..."
  sleep 2
done

sleep 3

# Get admin token with retries
echo "Getting admin token..."
TOKEN=""
a=0
while [ $a -lt 30 ]; do
  AUTH_RESPONSE=$(curl -s -X POST http://keycloak:8080/realms/master/protocol/openid-connect/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin" \
    -d "grant_type=password")

  TOKEN=$(printf '%s' "$AUTH_RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    break
  fi

  a=$((a+1))
  echo "Admin token not ready yet (attempt $a/30)"
  sleep 2
done

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to get admin token. Response: $AUTH_RESPONSE"
  echo "Tip: if this is an old Keycloak DB, reset with: docker compose down -v"
  exit 1
fi

echo "Admin token obtained"

# Get the mohan user ID
USERS=$(curl -s -X GET 'http://keycloak:8080/admin/realms/master/users?username=mohan' \
  -H "Authorization: Bearer $TOKEN")

USER_ID=$(printf '%s' "$USERS" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
  echo "Creating mohan user..."
  curl -s -X POST http://keycloak:8080/admin/realms/master/users \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "username": "mohan",
      "enabled": true,
      "emailVerified": true,
      "firstName": "Mohan",
      "lastName": "Admin",
      "email": "mohan@example.com"
    }' > /dev/null

  USERS=$(curl -s -X GET 'http://keycloak:8080/admin/realms/master/users?username=mohan' \
    -H "Authorization: Bearer $TOKEN")
  USER_ID=$(printf '%s' "$USERS" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
fi

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
  echo "Failed to get user ID"
  exit 1
fi

echo "User ID: $USER_ID"

# Set password for mohan user
echo "Setting password for mohan user..."
curl -s -X PUT http://keycloak:8080/admin/realms/master/users/$USER_ID/reset-password \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "password",
    "value": "mohan",
    "temporary": false
  }' > /dev/null

echo "Password set for mohan"

# Create OIDC client for Open WebUI
echo "Ensuring OIDC client for Open WebUI..."

CLIENTS=$(curl -s -X GET 'http://keycloak:8080/admin/realms/master/clients?clientId=open-webui' \
  -H "Authorization: Bearer $TOKEN")

CLIENT_ID=$(printf '%s' "$CLIENTS" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
  curl -s -X POST http://keycloak:8080/admin/realms/master/clients \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "open-webui",
      "name": "Open WebUI",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "PJa2eqYvlvRKT7kTEuzGsXpkg3fzPohB",
      "redirectUris": [
        "http://localhost:3000/oauth/oidc/callback",
        "http://localhost:3000/oauth/oidc/login/callback"
      ],
      "webOrigins": [
        "http://localhost:3000"
      ],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "attributes": {
        "post.logout.redirect.uris": "http://localhost:3000/auth"
      }
    }' > /dev/null

  CLIENTS=$(curl -s -X GET 'http://keycloak:8080/admin/realms/master/clients?clientId=open-webui' \
    -H "Authorization: Bearer $TOKEN")
  CLIENT_ID=$(printf '%s' "$CLIENTS" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
else
  curl -s -X PUT "http://keycloak:8080/admin/realms/master/clients/$CLIENT_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "id": "'"$CLIENT_ID"'",
      "clientId": "open-webui",
      "name": "Open WebUI",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "PJa2eqYvlvRKT7kTEuzGsXpkg3fzPohB",
      "redirectUris": [
        "http://localhost:3000/oauth/oidc/callback",
        "http://localhost:3000/oauth/oidc/login/callback"
      ],
      "webOrigins": [
        "http://localhost:3000"
      ],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "attributes": {
        "post.logout.redirect.uris": "http://localhost:3000/auth"
      }
    }' > /dev/null
fi

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
  echo "Failed to get client ID"
  exit 1
fi

echo "OIDC client ready: open-webui"

echo "=============================="
echo "Keycloak initialization complete!"
echo "=============================="
echo "Admin User: admin / admin"
echo "Custom User: mohan / mohan"
echo "OIDC Client: open-webui"
echo "Client Secret: PJa2eqYvlvRKT7kTEuzGsXpkg3fzPohB"
echo "=============================="
