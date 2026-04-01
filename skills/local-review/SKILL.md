---
name: local-review
description: Use this skill when you need to read or clear local-review.nvim comments.
---

# Local Review

Use this skill when the user asks to read, export, inspect, or clear `local-review.nvim` comments.

Run commands from the target repository root. Assume the plugin is already installed in the user's normal Neovim setup.

## Read comments

```sh
nvim --headless '+LocalReviewExport' \
  +qa
```

## Clear comments

```sh
nvim --headless '+LocalReviewClearRepo' \
  +qa
```

## Usage

If the user invokes the skill without any additional instructions, do the following:

1. Read the comments.
2. Generate a plan to address them. Get this approved by the user.
3. Make changes to the code.
4. Ask the user if they want to clear the comments and then clear them.

## Notes

Export before clearing unless the user explicitly asks to delete first.

