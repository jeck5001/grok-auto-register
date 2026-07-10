#!/usr/bin/env python3
"""Keep only the final token field from each non-empty input line."""

from __future__ import annotations

import argparse
import os
import tempfile
from pathlib import Path


DEFAULT_DELIMITER = "----"


def extract_tokens(lines: list[str], delimiter: str = DEFAULT_DELIMITER) -> list[str]:
    """Return the trimmed final field from every non-empty line."""
    tokens: list[str] = []
    for line in lines:
        value = line.strip()
        if not value:
            continue
        token = value.rsplit(delimiter, 1)[-1].strip()
        if token:
            tokens.append(token)
    return tokens


def write_atomic(path: Path, content: str) -> None:
    """Atomically replace a file using a temporary file in the same directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    except BaseException:
        temp_path.unlink(missing_ok=True)
        raise


def convert_file(source: Path, destination: Path | None = None, delimiter: str = DEFAULT_DELIMITER) -> int:
    if not source.is_file():
        raise FileNotFoundError(f"Input file does not exist: {source}")
    if not delimiter:
        raise ValueError("Delimiter must not be empty")

    lines = source.read_text(encoding="utf-8-sig").splitlines()
    tokens = extract_tokens(lines, delimiter)
    output = destination or source
    content = "".join(f"{token}\n" for token in tokens)
    write_atomic(output, content)
    return len(tokens)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Keep only the final token from lines formatted as account----password----token.",
    )
    parser.add_argument("file", type=Path, help="Input file. It is replaced in place by default.")
    parser.add_argument("-o", "--output", type=Path, help="Write to another file instead of replacing the input.")
    parser.add_argument("--delimiter", default=DEFAULT_DELIMITER, help="Field delimiter (default: ----).")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    count = convert_file(args.file.expanduser(), args.output.expanduser() if args.output else None, args.delimiter)
    target = args.output or args.file
    print(f"Processed {count} token(s): {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
