# CODEX Notes

## Token Efficiency in Terminal Workflows
- When creating a file in the terminal, avoid duplicating content output.
- Do not print the same content multiple times (for example, writing with a heredoc and then immediately `cat`-ing the full file unless validation is necessary).
- Prefer minimal confirmation commands such as `ls`, `wc -l`, or targeted `sed -n` snippets over full repeated dumps.
- Keep terminal output focused on what is needed to verify correctness.
