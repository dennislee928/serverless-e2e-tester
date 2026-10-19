#!/usr/bin/env python3
"""
Security scrubber for Robot Framework artifacts.

Reads sensitive values from environment variables and replaces them
(including XML/HTML/JS escaped variants) in artifact files with [SCRUBBED].

Design principles:
- Values are read from env vars only, never printed or logged
- Uses literal string replacement (no regex, no delimiters)
- Handles special chars: / $ | @ & < > " ' etc.
- Per-value try/except: single value failure skips only that value
- Always exits 0 to preserve Robot's original exit code
"""

import html
import os
import sys
from pathlib import Path


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
        js_html = html.escape(value, quote=False)
        js_html = js_html.replace("\\", "\\\\")
        js_html = js_html.replace('"', '\\"')
        js_html = js_html.replace("'", "\\'")
        js_html = js_html.replace("/", "\\/")
        variants.add(js_html)
    except Exception:
        pass
    
    return list(variants)


def scrub_file(filepath: Path, values_to_scrub: list[str]) -> int:
    """
    Scrub all sensitive values from a single file.
    Returns count of replacements made.
    Each value is processed in its own try/except to continue on single value failure.
    """
    replacements = 0
    
    try:
        content = filepath.read_text(encoding='utf-8', errors='replace')
    except Exception:
        return 0
    
    original_content = content
    
    for value in values_to_scrub:
        # Per-value try/except: single value failure skips only that value
        try:
            if not value or len(value) < 4:
                continue
            
            # Get all escaped variants for this value
            variants = get_escaped_variants(value)
            
            for variant in variants:
                if variant and variant in content:
                    content = content.replace(variant, "[SCRUBBED]")
                    replacements += 1
        except Exception:
            # Single value processing failed, continue with next value
            continue
    
    if content != original_content:
        try:
            filepath.write_text(content, encoding='utf-8')
        except Exception:
            pass
    
    return replacements


def main():
    """
    Main entry point.
    Reads report directory and scrub values from environment variables.
    """
    if len(sys.argv) < 2:
        sys.exit(0)
    
    report_dir = Path(sys.argv[1])
    if not report_dir.exists():
        sys.exit(0)
    
    # Collect values to scrub from environment variables
    values_to_scrub = []
    
    # Get TARGET_URL directly
    target_url = os.environ.get("_SCRUB_TARGET_URL", "")
    if target_url and target_url not in values_to_scrub:
        values_to_scrub.append(target_url)
    
    # Get RF_* prefixed values directly from environment
    for key, value in os.environ.items():
        if key.startswith("RF_") and value and len(value) >= 4:
            if value not in values_to_scrub:
                values_to_scrub.append(value)
    
    if not values_to_scrub:
        sys.exit(0)
    
    # Process all artifact files
    total_replacements = 0
    for pattern in ["*.xml", "*.html"]:
        for filepath in report_dir.glob(pattern):
            try:
                count = scrub_file(filepath, values_to_scrub)
                total_replacements += count
            except Exception:
                continue
    
    if total_replacements > 0:
        print(f"[SCRUBBER] Processed {total_replacements} replacement(s)")
    
    # Always exit 0 to preserve Robot's exit code
    sys.exit(0)


if __name__ == "__main__":
    main()
