#!/bin/bash

# Script to delete all Gmail emails from a specific sender
# Requires: Gmail API credentials and authentication

set -e

# Enable debugging
DEBUG=${DEBUG:-0}
debug_log() {
    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# Configuration
SENDER_EMAIL="$1"
ACCESS_TOKEN="$2"

if [ -z "$SENDER_EMAIL" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo "Usage: $0 <sender_email> <access_token>"
    echo ""
    echo "Example: $0 spam@example.com ya29.a0AfH6SMB..."
    echo ""
    echo "To get an access token:"
    echo "1. Go to https://developers.google.com/oauthplayground/"
    echo "2. Select 'Gmail API v1' and authorize ONE of these scopes:"
    echo "   Option A: https://www.googleapis.com/auth/gmail.modify"
    echo "             (Moves messages to Trash - safer, limited permissions)"
    echo "   Option B: https://mail.google.com/"
    echo "             (Permanently deletes messages - full Gmail access)"
    echo "3. Click 'Exchange authorization code for tokens'"
    echo "4. Copy the 'Access token' value"
    echo ""
    echo "Set DEBUG=1 to enable verbose logging: DEBUG=1 $0 ..."
    exit 1
fi

# Check dependencies
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

# Test access token validity
debug_log "Testing access token validity..."
TEST_RESPONSE=$(curl -s -X GET "https://gmail.googleapis.com/gmail/v1/users/me/profile" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -w "\nHTTP_STATUS:%{http_code}")

TEST_HTTP_STATUS=$(echo "$TEST_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
if [ "$TEST_HTTP_STATUS" != "200" ]; then
    echo "Error: Access token appears to be invalid or expired (HTTP $TEST_HTTP_STATUS)"
    TEST_RESPONSE_BODY=$(echo "$TEST_RESPONSE" | sed '/HTTP_STATUS:/d')
    if [ -n "$TEST_RESPONSE_BODY" ]; then
        echo "API Response: $TEST_RESPONSE_BODY"
    fi
    echo ""
    echo "Please get a new access token from: https://developers.google.com/oauthplayground/"
    exit 1
fi

debug_log "Access token is valid"

echo "Searching for emails from: $SENDER_EMAIL"

# Search for messages from the sender
SEARCH_QUERY="from:$SENDER_EMAIL"
ENCODED_QUERY=$(echo -n "$SEARCH_QUERY" | jq -sRr @uri)

# Collect all message IDs across all pages
ALL_MESSAGE_IDS=""
PAGE_TOKEN=""
PAGE_COUNT=1

echo "Fetching message list..."
debug_log "Search query: $SEARCH_QUERY"
debug_log "Encoded query: $ENCODED_QUERY"

while true; do
    debug_log "Processing page $PAGE_COUNT"

    # Build URL with page token if available
    if [ -z "$PAGE_TOKEN" ]; then
        URL="https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$ENCODED_QUERY&maxResults=500"
    else
        URL="https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$ENCODED_QUERY&maxResults=500&pageToken=$PAGE_TOKEN"
    fi

    debug_log "Fetching page $PAGE_COUNT from Gmail API..."
    debug_log "Full URL: $URL"

    # Get list of message IDs with timeout and better error handling

    RESPONSE=$(curl -s --connect-timeout 30 --max-time 60 -X GET "$URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -w "\nHTTP_STATUS:%{http_code}")

    # Check HTTP status
    HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')

    debug_log "HTTP Status: $HTTP_STATUS"
    debug_log "Response body length: $(echo "$RESPONSE_BODY" | wc -c)"

    if [ "$HTTP_STATUS" != "200" ]; then
        echo "Error: Gmail API returned HTTP $HTTP_STATUS"
        if [ -n "$RESPONSE_BODY" ]; then
            echo "Response: $RESPONSE_BODY"
        fi
        exit 1
    fi

    # Check for API errors in response body
    if echo "$RESPONSE_BODY" | jq -e '.error' > /dev/null 2>&1; then
        echo "Error from Gmail API:"
        echo "$RESPONSE_BODY" | jq '.error'
        exit 1
    fi

    # Extract message IDs from this page
    PAGE_MESSAGE_IDS=$(echo "$RESPONSE_BODY" | jq -r '.messages[]?.id // empty')

    if [ -n "$PAGE_MESSAGE_IDS" ]; then
        ALL_MESSAGE_IDS="$ALL_MESSAGE_IDS$PAGE_MESSAGE_IDS"$'\n'
        PAGE_MSG_COUNT=$(echo "$PAGE_MESSAGE_IDS" | wc -l | tr -d ' ')
        echo "  Found $PAGE_MSG_COUNT messages on page $PAGE_COUNT"
        debug_log "Sample message IDs: $(echo "$PAGE_MESSAGE_IDS" | head -3 | tr '\n' ' ')"
    else
        debug_log "Page $PAGE_COUNT: No messages found"
    fi

    PAGE_COUNT=$((PAGE_COUNT + 1))

    # Check for next page
    PAGE_TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.nextPageToken // empty')

    if [ -z "$PAGE_TOKEN" ]; then
        break
    fi
done

# Clean up the message IDs list
ALL_MESSAGE_IDS=$(echo "$ALL_MESSAGE_IDS" | grep -v '^$')
TOTAL_COUNT=$(echo "$ALL_MESSAGE_IDS" | wc -l | tr -d ' ')

if [ "$TOTAL_COUNT" -eq 0 ]; then
    echo "No messages found from $SENDER_EMAIL"
    exit 0
fi

echo ""
echo "Found $TOTAL_COUNT total messages to delete"
echo ""
read -p "Are you sure you want to delete all these messages? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Deletion cancelled"
    exit 0
fi

# Delete messages in batches (Gmail API allows up to 1000 IDs per batch request)
BATCH_SIZE=1000
DELETED=0
FAILED=0
BATCH_COUNT=1
USE_TRASH_ONLY=false

echo "Deleting messages in batches of $BATCH_SIZE..."

# Convert message IDs to array
IDS_ARRAY=($ALL_MESSAGE_IDS)

echo "Array length: ${#IDS_ARRAY[@]}"
echo "Total batches to process: $(( (${#IDS_ARRAY[@]} + BATCH_SIZE - 1) / BATCH_SIZE ))"
debug_log "First 3 message IDs in array: ${IDS_ARRAY[0]} ${IDS_ARRAY[1]} ${IDS_ARRAY[2]}"

echo "Starting batch deletion process..."
# Process in batches
for ((i=0; i<${#IDS_ARRAY[@]}; i+=BATCH_SIZE)); do
    echo "Processing batch $BATCH_COUNT..."

    # Get batch of IDs
    BATCH_IDS=("${IDS_ARRAY[@]:i:BATCH_SIZE}")
    BATCH_ACTUAL_SIZE=${#BATCH_IDS[@]}

    # Build JSON array of IDs
    JSON_IDS=$(printf '%s\n' "${BATCH_IDS[@]}" | jq -R . | jq -s .)

    if [ "$USE_TRASH_ONLY" = "true" ]; then
        # Skip delete attempt, go straight to trash
        echo "  Moving batch $BATCH_COUNT to Trash ($BATCH_ACTUAL_SIZE messages)..."
        debug_log "Using trash-only mode for $BATCH_ACTUAL_SIZE messages"

        # Use batchModify to add TRASH label and remove INBOX
        TRASH_REQUEST_BODY=$(jq -n --argjson ids "$JSON_IDS" '{
            ids: $ids,
            addLabelIds: ["TRASH"],
            removeLabelIds: ["INBOX"]
        }')

        echo -n "    Making API call to move messages... "
        BATCH_RESPONSE=$(curl -s --connect-timeout 30 --max-time 120 -X POST \
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/batchModify" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$TRASH_REQUEST_BODY" \
            -w "\nHTTP_STATUS:%{http_code}")

        HTTP_STATUS=$(echo "$BATCH_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
        if [ "$HTTP_STATUS" = "204" ]; then
            ((DELETED+=BATCH_ACTUAL_SIZE))
            echo "Done!"
            echo "    ✓ Successfully moved $BATCH_ACTUAL_SIZE messages to Trash (Total processed: $DELETED)"
        else
            ((FAILED+=BATCH_ACTUAL_SIZE))
            echo "Failed!"
            echo "    ✗ Failed to move to Trash (HTTP $HTTP_STATUS)"
            RESPONSE_BODY=$(echo "$BATCH_RESPONSE" | sed '/HTTP_STATUS:/d')
            if [ -n "$RESPONSE_BODY" ]; then
                echo "    Error: $RESPONSE_BODY"
            fi
        fi
    else
        # Try batch delete first
        # Create batch delete request body
        REQUEST_BODY=$(jq -n --argjson ids "$JSON_IDS" '{ids: $ids}')

        echo "  Deleting batch $BATCH_COUNT ($BATCH_ACTUAL_SIZE messages)..."

        echo -n "    Making API call to delete messages... "
        debug_log "Sending batch delete request for $BATCH_ACTUAL_SIZE messages"
        BATCH_RESPONSE=$(curl -s --connect-timeout 30 --max-time 120 -X POST \
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/batchDelete" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$REQUEST_BODY" \
            -w "\nHTTP_STATUS:%{http_code}")

        HTTP_STATUS=$(echo "$BATCH_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
        debug_log "Batch delete HTTP status: $HTTP_STATUS"

        if [ "$HTTP_STATUS" = "204" ]; then
            ((DELETED+=BATCH_ACTUAL_SIZE))
            echo "Done!"
            echo "    ✓ Successfully deleted $BATCH_ACTUAL_SIZE messages (Total processed: $DELETED)"
        elif [ "$HTTP_STATUS" = "403" ] && echo "$BATCH_RESPONSE" | grep -q "insufficientPermissions"; then
            # Switch to trash-only mode for remaining batches
            echo "    ⚠ Delete permission denied, switching to Trash mode for all remaining batches..."
            USE_TRASH_ONLY=true
            debug_log "Fallback: moving $BATCH_ACTUAL_SIZE messages to trash using batchModify"

            # Use batchModify to add TRASH label and remove INBOX
            TRASH_REQUEST_BODY=$(jq -n --argjson ids "$JSON_IDS" '{
                ids: $ids,
                addLabelIds: ["TRASH"],
                removeLabelIds: ["INBOX"]
            }')

            echo -n "    Making API call to move to Trash... "
            TRASH_RESPONSE=$(curl -s --connect-timeout 30 --max-time 120 -X POST \
                "https://gmail.googleapis.com/gmail/v1/users/me/messages/batchModify" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$TRASH_REQUEST_BODY" \
                -w "\nHTTP_STATUS:%{http_code}")

            TRASH_HTTP_STATUS=$(echo "$TRASH_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
            if [ "$TRASH_HTTP_STATUS" = "204" ]; then
                ((DELETED+=BATCH_ACTUAL_SIZE))
                echo "Done!"
                echo "    ✓ Successfully moved $BATCH_ACTUAL_SIZE messages to Trash (Total processed: $DELETED)"
            else
                ((FAILED+=BATCH_ACTUAL_SIZE))
                echo "Failed!"
                echo "    ✗ Failed to move to Trash (HTTP $TRASH_HTTP_STATUS)"
                TRASH_RESPONSE_BODY=$(echo "$TRASH_RESPONSE" | sed '/HTTP_STATUS:/d')
                if [ -n "$TRASH_RESPONSE_BODY" ]; then
                    echo "    Error: $TRASH_RESPONSE_BODY"
                fi
            fi
        else
            ((FAILED+=BATCH_ACTUAL_SIZE))
            echo "Failed!"
            echo "    ✗ Failed to delete batch (HTTP $HTTP_STATUS)"
            RESPONSE_BODY=$(echo "$BATCH_RESPONSE" | sed '/HTTP_STATUS:/d')
            if [ -n "$RESPONSE_BODY" ]; then
                echo "    Error: $RESPONSE_BODY"
            fi
        fi
    fi

    # Small delay to avoid rate limiting
    if [ $i -lt $((${#IDS_ARRAY[@]} - BATCH_SIZE)) ]; then
        sleep 0.5
    fi

    BATCH_COUNT=$((BATCH_COUNT + 1))
done

echo ""
echo "Operation complete!"
echo "Successfully processed: $DELETED"
echo "Failed: $FAILED"
echo ""
echo "Note: If messages were moved to Trash instead of deleted,"
echo "you can permanently delete them from Gmail's Trash folder."
