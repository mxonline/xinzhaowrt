#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ANSI_RE = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
LEADING_LINE_RE = re.compile(r'^\s*\d+:\s*')
SHA_RE = re.compile(r'\b[0-9a-fA-F]{40,64}\b')
RUN_RE = re.compile(r'(?i)(GitHub Actions Run ID:\s*)\d+')
WORKSPACE_RE = re.compile(r'/(?:home/runner/work|__w)/[^\s:]+')

PRIORITY_NAMES = [
    'failure-report.txt',
    'feed-error.txt',
    'error-summary.txt',
    'error-context.txt',
    'failed-steps.log',
    'feed-check.log',
    'build.log',
]

PATTERNS = {
    'missing-config': re.compile(r'(?i)\bMISSING:\s*(CONFIG_PACKAGE_[A-Za-z0-9_.+\-]+(?:=y)?)'),
    'missing-package': re.compile(r'(?i)\bMISSING_PACKAGE\b[:= ]*([^\r\n]*)'),
    'missing-source': re.compile(r'(?i)\bMISSING_SOURCE\b[:= ]*([^\r\n]*)'),
}

STRONG_ERROR_RE = re.compile(
    r'(?i)('
    r'\bERROR:\s*|\bfatal:\s*|No rule to make target|undefined reference|'
    r'collect2:\s*error|failed to build|package source.*no Makefile|'
    r'dependency.*does not exist|syntax error|No space left on device|'
    r'out of memory|hash check failed|download.*failed|'
    r'make\[[0-9]+\].*\*\*\*'
    r')'
)

STAGE_RE = re.compile(r'(?im)^(?:Failure stage|失败阶段)\s*[:：]\s*(.+?)\s*$')
FIRST_ERROR_RE = re.compile(r'(?im)^First real error\s*:\s*(.+?)\s*$')


def clean(text: str) -> str:
    return ANSI_RE.sub('', text.replace('\r', '\n'))


def normalize(line: str) -> str:
    line = ANSI_RE.sub('', line).replace('\r', ' ').strip()
    line = LEADING_LINE_RE.sub('', line)
    line = RUN_RE.sub(r'\1<run-id>', line)
    line = SHA_RE.sub('<sha>', line)
    line = WORKSPACE_RE.sub('<workspace>', line)
    line = re.sub(r'\s+', ' ', line)
    return line[:1000]


def ordered_files(root: Path):
    found = []
    seen = set()
    for name in PRIORITY_NAMES:
        for path in root.rglob(name):
            resolved = str(path.resolve())
            if resolved not in seen and path.is_file():
                seen.add(resolved)
                found.append(path)
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('diagnostics_dir')
    parser.add_argument('--output', default=None)
    args = parser.parse_args()

    root = Path(args.diagnostics_dir).resolve()
    files = ordered_files(root)
    texts = []
    stage = ''
    fallback_first_error = ''

    for path in files:
        try:
            text = clean(path.read_text(encoding='utf-8', errors='replace'))
        except OSError:
            continue
        texts.append((path, text))
        if not stage:
            match = STAGE_RE.search(text)
            if match:
                stage = normalize(match.group(1))
        if not fallback_first_error:
            match = FIRST_ERROR_RE.search(text)
            if match:
                fallback_first_error = normalize(match.group(1))

    buckets = {kind: [] for kind in PATTERNS}
    error_lines = []

    for _, text in texts:
        for raw in text.splitlines():
            line = normalize(raw)
            if not line:
                continue
            for kind, regex in PATTERNS.items():
                match = regex.search(line)
                if not match:
                    continue
                if kind == 'missing-config':
                    value = match.group(1)
                    if not value.endswith('=y'):
                        value += '=y'
                else:
                    value = match.group(1).strip(' :-') or line
                value = normalize(value)
                if value and value not in buckets[kind]:
                    buckets[kind].append(value)

            if 'WARNING:' not in line.upper() and STRONG_ERROR_RE.search(line):
                if line not in error_lines:
                    error_lines.append(line)

    if buckets['missing-config']:
        kind = 'missing-config'
        signals = sorted(buckets['missing-config'])
    elif buckets['missing-package']:
        kind = 'missing-package'
        signals = sorted(buckets['missing-package'])[:20]
    elif buckets['missing-source']:
        kind = 'missing-source'
        signals = sorted(buckets['missing-source'])[:20]
    elif error_lines:
        kind = 'error-lines'
        signals = error_lines[:12]
    elif fallback_first_error:
        kind = 'first-error'
        signals = [fallback_first_error]
    else:
        kind = 'unknown'
        signals = [stage or 'unknown-failure']

    root_payload = json.dumps(
        {'kind': kind, 'signals': signals},
        ensure_ascii=False,
        sort_keys=True,
        separators=(',', ':'),
    )
    context_payload = json.dumps(
        {'stage': stage, 'kind': kind, 'signals': signals},
        ensure_ascii=False,
        sort_keys=True,
        separators=(',', ':'),
    )

    result = {
        'schema_version': '1.0',
        'stage': stage or 'unknown',
        'kind': kind,
        'signals': signals,
        'root_signature': hashlib.sha256(root_payload.encode('utf-8')).hexdigest(),
        'context_signature': hashlib.sha256(context_payload.encode('utf-8')).hexdigest(),
        'source_files': [
            str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
            for path in files
        ],
        'generated_at': datetime.now(timezone.utc).isoformat(),
    }

    output = Path(args.output) if args.output else root / 'failure-fingerprint.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
