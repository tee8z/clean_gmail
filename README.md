# Gmail Email Cleaner

A bash script to bulk delete or move emails to trash using the Gmail API.

## Features

- Search for emails from specific senders
- Bulk delete emails (with full Gmail access) or move to Trash (with limited permissions)
- Automatic fallback from delete to trash based on your permissions
- Progress tracking with batch processing
- Debug mode for troubleshooting

## Requirements

- `curl` - for API requests
- `jq` - for JSON processing
- Gmail API access token

## Usage

```bash
./clear_emails.sh <sender_email> <access_token>
```

**Example:**
```bash
./clear_emails.sh spam@example.com ya29.a0AfH6SMB...
```

**With debug output:**
```bash
DEBUG=1 ./clear_emails.sh notifications@example.com ya29.a0AfH6SMB...
```

## Getting an Access Token

1. Go to [Google OAuth Playground](https://developers.google.com/oauthplayground/)
2. Select **Gmail API v1** and choose one of these scopes:
   - **Option A:** `https://www.googleapis.com/auth/gmail.modify` 
     - Moves messages to Trash (safer, limited permissions)
   - **Option B:** `https://mail.google.com/`
     - Permanently deletes messages (full Gmail access)
3. Click "Exchange authorization code for tokens"
4. Copy the **Access token** value

## How It Works

1. **Searches** for all emails from the specified sender
2. **Fetches** message IDs in batches of 500 (Gmail API limit)
3. **Processes** deletions in batches of 1000 messages
4. **Automatically detects** your permission level:
   - If you have full access (`mail.google.com`): permanently deletes
   - If you have limited access (`gmail.modify`): moves to Trash

## Safety Features

- Confirmation prompt before deletion
- Progress tracking with running totals
- Automatic fallback to safer Trash operation
- Rate limiting to avoid API quota issues
- Detailed error reporting

## Sample Output

```
Searching for emails from: notifications@example.com
Fetching message list...
  Found 500 messages on page 1
  Found 324 messages on page 2

Found 824 total messages to delete

Are you sure you want to delete all these messages? (yes/no): yes
Deleting messages in batches of 1000...
Array length: 824
Total batches to process: 1

Processing batch 1...
  Deleting batch 1 (824 messages)...
    Making API call to delete messages... Failed!
    ⚠ Delete permission denied, switching to Trash mode for all remaining batches...
    Making API call to move to Trash... Done!
    ✓ Successfully moved 824 messages to Trash (Total processed: 824)

Operation complete!
Successfully processed: 824
Failed: 0
```

## License

See LICENSE file for details.
