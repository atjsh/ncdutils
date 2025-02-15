<!--
SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
SPDX-License-Identifier: AGPL-3.0-only
-->

# ncdutils

Utilities for working with [ncdu](https://dev.yorhel.nl/ncdu) exports.

## Features

- find
- validate
- web, web-upload

## Added Features

These can be useful for cleaning up your data storage

- cleanup: List unnecessary directories like node_modules, (pytohn) venv, dist and more.
- freq: Show most frequent directory name
- largest: Show top 100 largest single files

## Building

Requirements:

- Crystal
- libzstd (with development files)
- pkg-config

Build:

```
shards build --release
```

## License

AGPL-3.0-only
