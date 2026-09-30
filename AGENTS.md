# Repository Instructions

- Keep code, identifiers, comments, and examples in English and use only generic public examples.
- Source lines allow 200 display columns; comments, docstrings, logging, and help text allow 240. These are ceilings, not targets or minimum lengths.
- Shorten without losing meaning, then wrap at semantic boundaries. Do not mechanically wrap at 80/100 columns or split URLs, regexes, placeholders, or copyable commands.
- Source physical line limits do not set rendered CLI help width. Rendered help descriptions allow 180 display columns, excluding option labels, alignment whitespace, and ANSI escapes.
- Author help, usage, and diagnostic prose as complete sentences or semantic clauses; preserve those boundaries instead of reflowing to terminal width. Align option continuations and keep tokens and copyable examples intact.
- Run every affected help entry and alias at narrow and wide terminal widths; test rendered widths and intact semantic lines. Do not change unrelated output or reformat historical source to enable a check.
- `tools/check_line_width.py` owns source thresholds; CLI formatters own rendered layout. Install the native pre-commit with `python -B tools/install_git_hooks.py`; preserve existing hooks and `core.hooksPath`.
- Before committing, run `python -B tools/check_line_width.py --staged`. It checks added/modified index lines, not unstaged worktree content or unchanged historical lines.
- Newly added/modified formatter width settings must match the 200-column code ceiling. Ordinary documents/data remain outside the commit gate; known width-policy files are checked.
- Use `python -B tools/check_line_width.py --all` for an explicit source inventory, or pass file paths for complete worktree audits. Documents and text data are explicit-only at 240 columns.
- Put new tests in the relevant tool's `tests/` subdirectory. Run layout regressions with `python -B -m unittest discover -s tools/tests -p 'test_*.py' -v`.
- Keep changes scoped and preserve existing commit identity protections. Do not add personal configuration paths, credentials, or dependencies on another repository.
