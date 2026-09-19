# BinderBooks / Card Tracker

## Testing

- **Run only the relevant test suites, not the full suite.** A full
  `xcodebuild test` run pays simulator-boot and package-resolution overhead
  every time — the tests themselves finish in well under a second. Use
  `-only-testing:BinderBooksTests/<SuiteName>` for each suite that covers the
  code you changed, e.g.:

  ```
  xcodebuild test -scheme BinderBooks \
    -destination 'id=<simulator-id>' -skipMacroValidation \
    -only-testing:BinderBooksTests/RecordEditorTests \
    -only-testing:BinderBooksTests/ScanSessionModelTests
  ```

  Find the destination id with `xcodebuild -showdestinations -scheme BinderBooks`.
  Only run the full suite when a change is broad enough that picking suites
  by hand is more work than just running everything.
- A plain `xcodebuild build` (no `test`) is enough to catch compile errors
  and is much cheaper than any `test` invocation — reach for it first.
