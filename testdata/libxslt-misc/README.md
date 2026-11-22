# libxslt feature regression corpora

Copied from the libxslt repository's `tests/documents`, `tests/encoding`,
`tests/keys`, `tests/namespaces`, `tests/numbers`, and `tests/reports`
directories so the XSLT engine can be checked against the reference
implementation's feature tests. Licensed under the MIT license; see
`COPYING`.

Run with:

```sh
zig build xslt-misc-suite
```

`tools/libxslt_misc_suite.py` tracks the currently known differences
explicitly; unexpected failures or newly fixed tests fail the gate until the
baseline is updated.
