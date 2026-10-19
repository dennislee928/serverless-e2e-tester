#!/usr/bin/env python3
"""
Security scrubber for Robot Framework artifacts.

Reads sensitive values from environment variables and replaces them
(including XML/HTML/JS escaped variants AND prefix truncations) in artifact
files with [SCRUBBED].

Design principles:
- Values are read from env vars only, never printed or logged
- Uses literal string replacement (no regex, no delimiters)
- Handles special chars: / $ | @ & < > " ' etc.
- Generates prefixes from MIN_PREFIX_LEN to full length for each value
- Replaces longest matches first to avoid partial replacements
- Per-value try/except: single value failure skips only that value
- Recursively processes entire report directory (second defense layer)
- Always exits 0 to preserve Robot's original exit code
- Extracts passwords from URL userinfo for independent scrubbing

PREFIX SCRUBBING:
- Minimum prefix length: 6 characters
- Rationale: 6 chars is long enough to avoid false positives on common
  strings while catching meaningful truncations. Security testing showed
  prefixes as short as 8-10 chars appearing in truncated logs.
- All escaped variants (raw, HTML quote=True/False, JS, Robot actual)
  are generated for each prefix length.
- Replacement order: longest to shortest, preventing short prefixes from
  consuming characters that are part of longer matches.
"""

import html
import os
import sys
from pathlib import Path
from urllib.parse import urlparse, unquote

# Minimum prefix length to scrub (see rationale in module docstring)
MIN_PREFIX_LEN = 6


def extract_url_password(url_value: str) -> list[str]:
    """
    Extract password from URL userinfo if present.
    Returns list of password variants (raw and URL-decoded) to add to scrub list.
    
    Handles URLs like: http://user:password@host:port/path
    Also handles URL-encoded passwords.
    """
    passwords = []
    if not url_value:
        return passwords
    
    try:
        parsed = urlparse(url_value)
        if parsed.password:
            raw_password = parsed.password
            passwords.append(raw_password)
            
            # Also add URL-decoded version if different
            try:
                decoded = unquote(raw_password)
                if decoded != raw_password and decoded not in passwords:
                    passwords.append(decoded)
            except Exception:
                pass
    except Exception:
        pass
    
    return passwords


def get_escaped_variants(value: str) -> list[str]:
    """
    Generate all common escaped variants of a value.
    Returns list of variants to search for, including the original.
    
    Covers:
    - Raw value
    - html.escape(quote=True): & < > " ' all escaped
    - html.escape(quote=False): & < > escaped, quotes remain
    - JS escaped: backslash-quote, backslash-slash for log.html JavaScript strings
    - Various HTML entity forms for quotes
    """
    variants = set()
    variants.add(value)
    
    if not value:
        return list(variants)
    
    # html.escape with quote=True (escapes & < > " ')
    try:
        escaped_quote_true = html.escape(value, quote=True)
        variants.add(escaped_quote_true)
    except Exception:
        pass
    
    # html.escape with quote=False (escapes & < > only, quotes remain)
    try:
        escaped_quote_false = html.escape(value, quote=False)
        variants.add(escaped_quote_false)
    except Exception:
        pass
    
    # Manual HTML entity escaping with different quote forms
    try:
        # &quot; for double quote, &#x27; for single quote
        manual_escaped = value.replace("&", "&amp;")
        manual_escaped = manual_escaped.replace("<", "&lt;")
        manual_escaped = manual_escaped.replace(">", "&gt;")
        manual_escaped = manual_escaped.replace('"', "&quot;")
        manual_escaped = manual_escaped.replace("'", "&#x27;")
        variants.add(manual_escaped)
    except Exception:
        pass
    
    try:
        # &#39; for single quote variant
        manual_escaped_39 = value.replace("&", "&amp;")
        manual_escaped_39 = manual_escaped_39.replace("<", "&lt;")
        manual_escaped_39 = manual_escaped_39.replace(">", "&gt;")
        manual_escaped_39 = manual_escaped_39.replace('"', "&quot;")
        manual_escaped_39 = manual_escaped_39.replace("'", "&#39;")
        variants.add(manual_escaped_39)
    except Exception:
        pass
    
    try:
        # &apos; for single quote (XML style)
        manual_escaped_apos = value.replace("&", "&amp;")
        manual_escaped_apos = manual_escaped_apos.replace("<", "&lt;")
        manual_escaped_apos = manual_escaped_apos.replace(">", "&gt;")
        manual_escaped_apos = manual_escaped_apos.replace('"', "&quot;")
        manual_escaped_apos = manual_escaped_apos.replace("'", "&apos;")
        variants.add(manual_escaped_apos)
    except Exception:
        pass
    
    # JavaScript string escaping (for log.html embedded JS)
    try:
        js_escaped = value.replace("\\", "\\\\")
        js_escaped = js_escaped.replace('"', '\\"')
        js_escaped = js_escaped.replace("'", "\\'")
        js_escaped = js_escaped.replace("/", "\\/")
        variants.add(js_escaped)
    except Exception:
        pass
    
    # JS escaped combined with HTML escaping (log.html has JS with HTML-escaped content)
    try:
        js_html_wrong = html.escape(value, quote=False)
        js_html_wrong = js_html_wrong.replace("\\", "\\\\")
        js_html_wrong = js_html_wrong.replace('"', '\\"')
        js_html_wrong = js_html_wrong.replace("'", "\\'")
        js_html_wrong = js_html_wrong.replace("/", "\\/")
        variants.add(js_html_wrong)
    except Exception:
        pass
    
    # Robot ACTUAL form in log.html/report.html:
    # html.escape(quote=False) then ONLY " → \" (single quote ' and / are NOT escaped)
    try:
        robot_actual = html.escape(value, quote=False)
        robot_actual = robot_actual.replace('"', '\\"')
        variants.add(robot_actual)
    except Exception:
        pass
    
    return list(variants)


def generate_prefixes_with_variants(value: str) -> list[str]:
    """
    Generate all prefixes of a value from full length down to MIN_PREFIX_LEN,
    along with all escaped variants of each prefix.
    
    Returns list sorted by length descending (longest first) to ensure
    longer matches are replaced before shorter ones.
    """
    all_variants = set()
    
    if not value or len(value) < MIN_PREFIX_LEN:
        return []
    
    # Generate prefixes from full length down to MIN_PREFIX_LEN
    for prefix_len in range(len(value), MIN_PREFIX_LEN - 1, -1):
        prefix = value[:prefix_len]
        # Get all escaped variants for this prefix
        variants = get_escaped_variants(prefix)
        all_variants.update(variants)
    
    # Sort by length descending (longest first)
    sorted_variants = sorted(all_variants, key=len, reverse=True)
    return sorted_variants


def is_text_file(filepath: Path) -> bool:
    """
    Check if a file appears to be a text file that can be safely processed.
    Returns False for binary files or files that can't be decoded.
    """
    try:
        with open(filepath, 'rb') as f:
            chunk = f.read(8192)
            # Check for null bytes (binary indicator)
            if b'\x00' in chunk:
                return False
            # Try to decode as UTF-8
            try:
                chunk.decode('utf-8')
                return True
            except UnicodeDecodeError:
                # Try latin-1 as fallback
                try:
                    chunk.decode('latin-1')
                    return True
                except Exception:
                    return False
    except Exception:
        return False


def scrub_file(filepath: Path, variants_to_scrub: list[str]) -> int:
    """
    Scrub all sensitive values from a single file.
    Returns count of replacements made.
    Variants should already be sorted longest-first.
    """
    replacements = 0
    
    try:
        content = filepath.read_text(encoding='utf-8', errors='replace')
    except Exception:
        return 0
    
    original_content = content
    
    for variant in variants_to_scrub:
        try:
            if variant and len(variant) >= MIN_PREFIX_LEN and variant in content:
                content = content.replace(variant, "[SCRUBBED]")
                replacements += 1
        except Exception:
            continue
    
    if content != original_content:
        try:
            filepath.write_text(content, encoding='utf-8')
        except Exception:
            pass
    
    return replacements


def get_files_to_process(report_dir: Path) -> list[Path]:
    """
    Get all text files in report_dir recursively.
    Includes: *.xml, *.html, *.txt, *.log, *.out, and extensionless text files.
    Excludes: binary files, files that can't be decoded.
    """
    files = []
    text_extensions = {'.xml', '.html', '.htm', '.txt', '.log', '.out'}
    
    try:
        for filepath in report_dir.rglob('*'):
            if not filepath.is_file():
                continue
            
            suffix = filepath.suffix.lower()
            
            # Include known text extensions
            if suffix in text_extensions:
                if is_text_file(filepath):
                    files.append(filepath)
            # Include extensionless files if they're text
            elif suffix == '' and is_text_file(filepath):
                files.append(filepath)
    except Exception:
        pass
    
    return files


def main():
    """
    Main entry point.
    Reads report directory and scrub values from environment variables.
    Recursively processes all text files in the directory tree.
    """
    if len(sys.argv) < 2:
        sys.exit(0)
    
    report_dir = Path(sys.argv[1])
    if not report_dir.exists():
        sys.exit(0)
    
    # Collect base values to scrub from environment variables
    base_values = []
    
    # Get TARGET_URL directly
    target_url = os.environ.get("_SCRUB_TARGET_URL", "")
    if target_url and target_url not in base_values:
        base_values.append(target_url)
        # Extract password from URL userinfo for independent scrubbing
        for pwd in extract_url_password(target_url):
            if pwd and len(pwd) >= MIN_PREFIX_LEN and pwd not in base_values:
                base_values.append(pwd)
    
    # Get RF_* prefixed values directly from environment
    for key, value in os.environ.items():
        if key.startswith("RF_") and value and len(value) >= MIN_PREFIX_LEN:
            if value not in base_values:
                base_values.append(value)
            # Check if RF_* value looks like a URL with userinfo
            if "://" in value and "@" in value:
                for pwd in extract_url_password(value):
                    if pwd and len(pwd) >= MIN_PREFIX_LEN and pwd not in base_values:
                        base_values.append(pwd)
    
    if not base_values:
        sys.exit(0)
    
    # Generate all variants including prefixes, sorted longest-first
    all_variants = []
    seen = set()
    for value in base_values:
        prefixed_variants = generate_prefixes_with_variants(value)
        for v in prefixed_variants:
            if v not in seen:
                seen.add(v)
                all_variants.append(v)
    
    # Re-sort all variants by length descending
    all_variants.sort(key=len, reverse=True)
    
    # Get all text files recursively
    files_to_process = get_files_to_process(report_dir)
    
    # Process all files
    total_replacements = 0
    for filepath in files_to_process:
        try:
            count = scrub_file(filepath, all_variants)
            total_replacements += count
        except Exception:
            continue
    
    if total_replacements > 0:
        print(f"[SCRUBBER] Processed {total_replacements} replacement(s) in {len(files_to_process)} file(s)")
    
    # Always exit 0 to preserve Robot's exit code
    sys.exit(0)


if __name__ == "__main__":
    main()
