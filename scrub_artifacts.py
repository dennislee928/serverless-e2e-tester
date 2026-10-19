#!/usr/bin/env python3
"""
Security scrubber for Robot Framework artifacts.

Reads sensitive values from environment variables and replaces them
(including XML/HTML escaped variants) in artifact files with [SCRUBBED].

Design principles:
- Values are read from env vars only, never printed or logged
- Uses literal string replacement (no regex, no delimiters)
- Handles special chars: / $ | @ & < > etc.
- Single value failure is caught, processing continues
- Always exits 0 to preserve Robot's original exit code
"""

import html
import os
import sys
from pathlib import Path


def get_escaped_variants(value: str) -> list[str]:
    """
    Generate common escaped variants of a value.
    Returns list of variants to search for, including the original.
    """
    variants = [value]
    
    if not value:
        return variants
    
    # XML/HTML entity escaping
    xml_escaped = html.escape(value, quote=True)
    if xml_escaped != value:
        variants.append(xml_escaped)
    
    # Additional HTML numeric escapes for quotes
    # ' can be &#x27; or &#39; or &apos;
    html_escaped = value.replace("&", "&amp;")
    html_escaped = html_escaped.replace("<", "&lt;")
    html_escaped = html_escaped.replace(">", "&gt;")
    html_escaped = html_escaped.replace('"', "&quot;")
    html_escaped = html_escaped.replace("'", "&#x27;")
    if html_escaped not in variants:
        variants.append(html_escaped)
    
    # Variant with &#39; for single quote
    html_escaped_alt = value.replace("&", "&amp;")
    html_escaped_alt = html_escaped_alt.replace("<", "&lt;")
    html_escaped_alt = html_escaped_alt.replace(">", "&gt;")
    html_escaped_alt = html_escaped_alt.replace('"', "&quot;")
    html_escaped_alt = html_escaped_alt.replace("'", "&#39;")
    if html_escaped_alt not in variants:
        variants.append(html_escaped_alt)
    
    # Variant with &apos; for single quote (XML)
    xml_apos = value.replace("&", "&amp;")
    xml_apos = xml_apos.replace("<", "&lt;")
    xml_apos = xml_apos.replace(">", "&gt;")
    xml_apos = xml_apos.replace('"', "&quot;")
    xml_apos = xml_apos.replace("'", "&apos;")
    if xml_apos not in variants:
        variants.append(xml_apos)
    
    return variants


def scrub_file(filepath: Path, values_to_scrub: list[str]) -> int:
    """
    Scrub all sensitive values from a single file.
    Returns count of replacements made.
    """
    replacements = 0
    
    try:
        content = filepath.read_text(encoding='utf-8', errors='replace')
        original_content = content
        
        for value in values_to_scrub:
            if not value or len(value) < 4:
                continue
            
            # Get all escaped variants
            variants = get_escaped_variants(value)
            
            for variant in variants:
                if variant in content:
                    content = content.replace(variant, "[SCRUBBED]")
                    replacements += 1
        
        if content != original_content:
            filepath.write_text(content, encoding='utf-8')
            
    except Exception:
        # Silently continue on any error for this file
        pass
    
    return replacements


def main():
    """
    Main entry point.
    Reads report directory and scrub values from environment variables.
    """
    if len(sys.argv) < 2:
        # No report directory specified, exit silently
        sys.exit(0)
    
    report_dir = Path(sys.argv[1])
    if not report_dir.exists():
        sys.exit(0)
    
    # Collect values to scrub from environment variables
    # SCRUB_VALUES is a newline-separated list passed via env
    # We also check for TARGET_URL directly
    values_to_scrub = []
    
    # Read from SCRUB_VALUES_FILE if exists (contains base64 or raw values)
    scrub_env = os.environ.get("_SCRUB_VALUES", "")
    if scrub_env:
        values_to_scrub.extend(v for v in scrub_env.split("\x00") if v)
    
    # Also get TARGET_URL directly
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
                # Continue on any error
                continue
    
    # Print only the count, never the values
    if total_replacements > 0:
        print(f"[SCRUBBER] Processed {total_replacements} replacement(s)")
    
    # Always exit 0 to not affect Robot's exit code
    sys.exit(0)


if __name__ == "__main__":
    main()
