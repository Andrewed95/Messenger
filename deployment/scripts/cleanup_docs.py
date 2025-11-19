#!/usr/bin/env python3
"""
Documentation Cleanup Script
Removes version metadata, time estimates, cost estimates, and cross-references from documentation
"""

import re
import os
from pathlib import Path

# Statistics tracking
stats = {
    'files_processed': 0,
    'time_estimates_removed': 0,
    'cost_sections_removed': 0,
    'cross_references_removed': 0,
    'version_metadata_removed': 0,
    'network_sections_removed': 0
}

def remove_metadata_lines(content):
    """Remove 'Last Updated:' and 'Document Version:' lines"""
    original_count = content.count('\n')

    # Remove Last Updated lines
    content = re.sub(r'^\*\*Last Updated:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove Document Version lines
    content = re.sub(r'^\*\*Document Version:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove lines with just dates
    content = re.sub(r'^\*\*Date:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove "Maintained By" lines
    content = re.sub(r'^\*\*Maintained By:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove "Next Review" lines
    content = re.sub(r'^\*\*Next Review:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove "Tested On" lines
    content = re.sub(r'^\*\*Tested On:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove "Reviewed By" lines
    content = re.sub(r'^\*\*Reviewed By:\*\*.*$', '', content, flags=re.MULTILINE)
    # Remove "Ready for Production" lines
    content = re.sub(r'^\*\*Ready for Production:\*\*.*$', '', content, flags=re.MULTILINE)

    new_count = content.count('\n')
    stats['version_metadata_removed'] += (original_count - new_count)

    return content

def remove_time_estimates(content):
    """Remove time estimates like '2-4 days', '15-30 minutes', etc."""
    # Find and count time estimates
    patterns = [
        r'\d+-\d+\s+(minute|hour|day|week|month)s?',
        r'\d+\s+(minute|hour|day|week|month)s?',
        r'takes?\s+\d+-\d+\s+(minute|hour|day|week|month)s?',
        r'\*\*Time Required:\*\*[^\n]*',
        r'\*\*TOTAL TIME:\*\*[^\n]*',
        r'^\d+\.\s+\*\*Day \d+[^\*]*\*\*[^\n]*$',  # Timeline entries
    ]

    for pattern in patterns:
        matches = re.findall(pattern, content, flags=re.IGNORECASE | re.MULTILINE)
        stats['time_estimates_removed'] += len(matches)
        content = re.sub(pattern, '', content, flags=re.IGNORECASE | re.MULTILINE)

    return content

def remove_cost_sections(content):
    """Remove cost estimate sections and pricing information"""
    # Count cost sections
    cost_section_pattern = r'###?\s+\d+\.\d+\s+Cost Estimate.*?(?=###?\s+\d+\.\d+|###?\s+\d+\s+[A-Z]|^---$|\Z)'
    matches = re.findall(cost_section_pattern, content, flags=re.DOTALL | re.MULTILINE)
    stats['cost_sections_removed'] += len(matches)

    # Remove cost sections
    content = re.sub(cost_section_pattern, '', content, flags=re.DOTALL | re.MULTILINE)

    # Remove cost lines
    content = re.sub(r'^\*\*Infrastructure \(Cloud\):\*\*.*?^\*\*Total:.*$', '', content, flags=re.MULTILINE | re.DOTALL)
    content = re.sub(r'^\*\*Infrastructure \(On-Premises\):\*\*.*?^\*\*Amortized.*$', '', content, flags=re.MULTILINE | re.DOTALL)
    content = re.sub(r'- Compute:.*\$.*$', '', content, flags=re.MULTILINE)
    content = re.sub(r'- Storage:.*\$.*$', '', content, flags=re.MULTILINE)
    content = re.sub(r'- Network:.*\$.*$', '', content, flags=re.MULTILINE)
    content = re.sub(r'- Servers:.*\$.*$', '', content, flags=re.MULTILINE)

    return content

def remove_network_sections(content):
    """Remove Network Requirements sections"""
    # Remove network requirement sections
    network_pattern = r'###?\s+\d+\.\d+\s+Network Requirements.*?(?=###?\s+\d+\.\d+|###?\s+\d+\s+[A-Z]|^---$|\Z)'
    matches = re.findall(network_pattern, content, flags=re.DOTALL | re.MULTILINE)
    stats['network_sections_removed'] += len(matches)
    content = re.sub(network_pattern, '', content, flags=re.DOTALL | re.MULTILINE)

    return content

def remove_cross_references(content):
    """Remove cross-references to other documentation"""
    patterns = [
        r'^\*\*See also:\*\*.*$',
        r'^\*\*Read next:\*\*.*$',
        r'^\*\*For more details, see:.*$',
        r'^\*\*Related:\*\*.*$',
        r'See \[.*?\]\(.*?\.md\) for.*',
    ]

    for pattern in patterns:
        matches = re.findall(pattern, content, flags=re.MULTILINE)
        stats['cross_references_removed'] += len(matches)
        content = re.sub(pattern, '', content, flags=re.MULTILINE)

    return content

def clarify_formulas(content):
    """Add clarifications to resource formulas"""
    # Clarify PostgreSQL CPU is per instance
    content = re.sub(
        r'PostgreSQL CPU = 2 vCPU \(base\) \+ \(CCU / 5000\) × 2 vCPU',
        'PostgreSQL CPU = 2 vCPU (base) + (CCU / 5000) × 2 vCPU (per PostgreSQL instance)',
        content
    )

    # Clarify PostgreSQL RAM is per instance
    content = re.sub(
        r'PostgreSQL RAM = 4GB \(base\) \+ \(CCU / 1000\) × 1GB',
        'PostgreSQL RAM = 4GB (base) + (CCU / 1000) × 1GB (per PostgreSQL instance)',
        content
    )

    return content

def add_parameter_explanations(content):
    """Add explanations for media_retention_period and max_upload_size"""
    # Add explanation for media_retention_period
    content = re.sub(
        r'(media_retention:\n  local_media_lifetime: \d+d)',
        r'\1  # How long to keep local media files cached on disk before deletion\n  # Files remain in MinIO (S3) permanently unless explicitly deleted',
        content
    )

    # Add explanation for max_upload_size
    content = re.sub(
        r'(max_upload_size: \d+M)',
        r'\1  # Maximum file size for media uploads (images, documents, etc.)',
        content
    )

    return content

def fix_ccu_inconsistencies(content):
    """Fix CCU vs employee count inconsistencies"""
    # Remove employee count references
    content = re.sub(r'Medium-sized organizations \(\d+-\d+ employees\)', 'Medium-sized organizations', content)
    content = re.sub(r'Large organizations \(\d+-\d+ employees\)', 'Large organizations', content)
    content = re.sub(r'Enterprise organizations \(\d+-\d+ employees\)', 'Enterprise organizations', content)

    return content

def clean_multiple_blank_lines(content):
    """Replace multiple consecutive blank lines with maximum 2 blank lines"""
    content = re.sub(r'\n{4,}', '\n\n\n', content)
    return content

def process_file(filepath):
    """Process a single markdown file"""
    print(f"Processing: {filepath}")

    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_content = content

    # Apply all transformations
    content = remove_metadata_lines(content)
    content = remove_time_estimates(content)
    content = remove_cost_sections(content)
    content = remove_network_sections(content)
    content = remove_cross_references(content)
    content = clarify_formulas(content)
    content = add_parameter_explanations(content)
    content = fix_ccu_inconsistencies(content)
    content = clean_multiple_blank_lines(content)

    # Only write if changed
    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        stats['files_processed'] += 1
        return True

    return False

def main():
    deployment_dir = Path(__file__).parent.parent

    # Process all markdown files in docs/
    docs_dir = deployment_dir / 'docs'
    if docs_dir.exists():
        for md_file in docs_dir.glob('*.md'):
            process_file(md_file)

    # Process all README.md files in subdirectories (except docs/)
    for readme in deployment_dir.glob('*/README.md'):
        if 'docs' not in str(readme):
            process_file(readme)

    for readme in deployment_dir.glob('*/*/README.md'):
        process_file(readme)

    # Process main README.md
    main_readme = deployment_dir / 'README.md'
    if main_readme.exists():
        process_file(main_readme)

    # Print statistics
    print("\n" + "=" * 60)
    print("DOCUMENTATION CLEANUP SUMMARY")
    print("=" * 60)
    print(f"Files processed: {stats['files_processed']}")
    print(f"Version metadata lines removed: {stats['version_metadata_removed']}")
    print(f"Time estimates removed: {stats['time_estimates_removed']}")
    print(f"Cost sections removed: {stats['cost_sections_removed']}")
    print(f"Network requirement sections removed: {stats['network_sections_removed']}")
    print(f"Cross-references removed: {stats['cross_references_removed']}")
    print("=" * 60)

if __name__ == '__main__':
    main()
