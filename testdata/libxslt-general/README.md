# libxslt general regression suite

Copied from the libxslt repository (`tests/general`) so the XSLT engine can
be checked against the reference implementation's own regression corpus.
Licensed under the MIT license; see `COPYING`.

Run with:

```sh
zig build xslt-suite
```

`tools/libxslt_suite.py` tracks the currently known differences explicitly;
unexpected failures or newly fixed tests fail the gate until the baseline is
updated.
