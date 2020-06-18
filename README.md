A Tox bot for recording audio

# Build

## Nix

```sh
nix-shell
nimble build
```

# Configuration

The following environmental variables affect the bot behavior:

 * TOX_ADMIN_ID - Friends to add to the bot
 * TOX_AVATAR_FILE - Location of avatar image, in PNG format
 * TOX_CONFERENCE_TITLE - Title of conference created by bot
 * TOX_DATA_FILE - Location of Tox save data
 * TOX_NAME - Display name of bot
 * TOX_RECORDINGS_DIR - Directory to write recordings into
 * TOX_STATUS - Status message of bot

