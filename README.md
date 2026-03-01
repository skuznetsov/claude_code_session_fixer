# Claude Code Session Fixer

Small Crystal CLI tool to repair broken Claude Code session files by removing
`thinking` and `redacted_thinking` blocks from assistant messages in `.jsonl`
sessions.

## What It Does

- Scans Claude sessions under `~/.claude/projects/*/*.jsonl`.
- Finds assistant messages that contain `thinking` / `redacted_thinking` blocks.
- Removes only those blocks from `message.content`.
- Drops a line if, after removal, `content` becomes empty.
- Creates a backup before writing changes.

## Why

Some Claude session files can become hard to resume when internal thinking
blocks are present or malformed for downstream tooling. This utility performs a
targeted cleanup without changing unrelated JSON fields.

## Requirements

- Crystal `>= 1.10.0`

## Build

```bash
crystal build src/session_fixer.cr -o session_fixer
```

## Usage

```bash
# Show help
./session_fixer --help

# List sessions that contain thinking blocks
./session_fixer --list

# Fix by full or partial session ID
./session_fixer <session-id>

# Fix by direct file path
./session_fixer /absolute/path/to/session.jsonl

# Preview changes only (no write)
./session_fixer <session-id-or-path> --dry-run
```

You can also run without building:

```bash
crystal run src/session_fixer.cr -- --list
crystal run src/session_fixer.cr -- <session-id> --dry-run
```

## Session Selection Rules

When you pass an ID (not a file path), matching is:

1. Exact UUID match first.
2. Partial UUID match second.
3. If multiple matches are found, the tool stops with an ambiguity error and
   asks for a longer ID or full path.

## Safety and Backups

- Normal mode writes to a temporary file, then replaces the original.
- A backup is created first:
  - preferred: `<session>.bak.jsonl`
  - if that already exists: `<session>.bak.<timestamp>.jsonl`
- `--dry-run` never modifies the source file.

## Output Stats

After processing, the tool reports:

- total lines
- modified lines
- removed lines (where content became empty)
- number of thinking blocks removed
- parse errors skipped (if any malformed JSON lines were encountered)

## Limitations

- Only assistant messages are modified.
- Non-JSON lines are skipped (counted as parse errors).
- The tool assumes standard Claude session layout under `~/.claude/projects/`.

