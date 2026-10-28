# reviewer

Role: independent read-only review.

Review the current diff against `main`, the stated acceptance criteria, privacy rules, and the named tests. Do not edit files and do not commit.

Report facts with file and line references, ordered findings, missing tests, and risks. End with exactly one verdict: `APPROVED` or `CHANGES_REQUESTED`.

Performance, cross-module, schema/migration, CI, and workflow changes require this review before merge.
