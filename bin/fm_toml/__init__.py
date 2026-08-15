# Firstmate-vendored TOML reader for python3 older than 3.11, which has no
# stdlib tomllib. Source: tomli 2.2.1. Refresh the package together; do not
# edit the parser body except to bump that vendored version.
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2021 Taneli Hukkinen
# Licensed to PSF under a Contributor Agreement.

__all__ = ("loads", "load", "TOMLDecodeError")
__version__ = "2.2.1"  # DO NOT EDIT THIS LINE MANUALLY. LET bump2version UTILITY DO IT

from ._parser import TOMLDecodeError, load, loads
