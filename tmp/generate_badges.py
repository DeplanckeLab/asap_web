#!/usr/bin/env python3
"""Generate scFAIR compliance badge SVGs using the actual scfair.svg logo."""

import re

# Read the scfair.svg logo
with open('src/app/assets/images/scfair.svg', 'r') as f:
    svg_content = f.read()

# Extract path elements (d attribute and fill attribute)
path_pattern = r'<path d="([^"]*)" fill="([^"]*)"/>'
matches = re.findall(path_pattern, svg_content)

if len(matches) != 4:
    print(f"ERROR: Expected 4 paths, found {len(matches)}")
    exit(1)

# Build the path group lines for embedding
paths_lines = '\n'.join(
    [f'      <path d="{d}" fill="{fill}"/>' for d, fill in matches]
)

print(f"Extracted {len(matches)} paths from scfair.svg")
for i, (d, fill) in enumerate(matches):
    print(f"  Path {i+1}: fill={fill}, d length={len(d)} chars")

# --- Compliant badge (full color logo, green right panel) ---
compliant_svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="240" height="44" viewBox="0 0 240 44">
  <defs>
    <linearGradient id="bg-left" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#0f1f3d"/>
      <stop offset="100%" stop-color="#0a1628"/>
    </linearGradient>
    <linearGradient id="bg-right-ok" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#22c55e"/>
      <stop offset="100%" stop-color="#16a34a"/>
    </linearGradient>
  </defs>
  <!-- Left panel: scFAIR branding -->
  <rect x="0" y="0" width="120" height="44" rx="6" ry="6" fill="url(#bg-left)"/>
  <rect x="114" y="0" width="6" height="44" fill="url(#bg-left)"/>
  <!-- Right panel: COMPLIANT -->
  <rect x="120" y="0" width="120" height="44" rx="6" ry="6" fill="url(#bg-right-ok)"/>
  <rect x="120" y="0" width="6" height="44" fill="url(#bg-right-ok)"/>
  <!-- scFAIR logo (icon portion, clipped by nested svg viewport) -->
  <svg x="2" y="1" width="50" height="42" viewBox="90 90 790 760">
    <g>
{paths_lines}
    </g>
  </svg>
  <!-- scFAIR text -->
  <text x="85" y="28" font-family="Arial, Helvetica, sans-serif" font-size="15" font-weight="bold" fill="white" text-anchor="middle">
    <tspan fill="#a0d0e0">sc</tspan><tspan fill="white">FAIR</tspan>
  </text>
  <!-- COMPLIANT text -->
  <text x="180" y="28" font-family="Arial, Helvetica, sans-serif" font-size="13" font-weight="bold" fill="white" text-anchor="middle" letter-spacing="0.5">COMPLIANT</text>
  <!-- Outer border -->
  <rect x="0.5" y="0.5" width="239" height="43" rx="6" ry="6" fill="none" stroke="rgba(255,255,255,0.15)" stroke-width="1"/>
</svg>'''

# --- Non-compliant badge (greyed logo, red right panel) ---
noncompliant_svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="280" height="44" viewBox="0 0 280 44">
  <defs>
    <linearGradient id="bg-left-nc" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#1a1a24"/>
      <stop offset="100%" stop-color="#121218"/>
    </linearGradient>
    <linearGradient id="bg-right-nc" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#dc2626"/>
      <stop offset="100%" stop-color="#b91c1c"/>
    </linearGradient>
    <filter id="grey-muted">
      <feColorMatrix type="saturate" values="0"/>
      <feComponentTransfer>
        <feFuncR type="linear" slope="0.5" intercept="0.17"/>
        <feFuncG type="linear" slope="0.5" intercept="0.17"/>
        <feFuncB type="linear" slope="0.5" intercept="0.17"/>
      </feComponentTransfer>
    </filter>
  </defs>
  <!-- Left panel: scFAIR branding (greyed) -->
  <rect x="0" y="0" width="120" height="44" rx="6" ry="6" fill="url(#bg-left-nc)"/>
  <rect x="114" y="0" width="6" height="44" fill="url(#bg-left-nc)"/>
  <!-- Right panel: NON-COMPLIANT -->
  <rect x="120" y="0" width="160" height="44" rx="6" ry="6" fill="url(#bg-right-nc)"/>
  <rect x="120" y="0" width="6" height="44" fill="url(#bg-right-nc)"/>
  <!-- scFAIR logo (greyscale + muted) -->
  <svg x="2" y="1" width="50" height="42" viewBox="90 90 790 760">
    <g filter="url(#grey-muted)">
{paths_lines}
    </g>
  </svg>
  <!-- scFAIR text (greyed) -->
  <text x="85" y="28" font-family="Arial, Helvetica, sans-serif" font-size="15" font-weight="bold" fill="#999" text-anchor="middle">
    <tspan fill="#888">sc</tspan><tspan fill="#aaa">FAIR</tspan>
  </text>
  <!-- NON-COMPLIANT text -->
  <text x="200" y="28" font-family="Arial, Helvetica, sans-serif" font-size="12" font-weight="bold" fill="white" text-anchor="middle" letter-spacing="0.5">NON-COMPLIANT</text>
  <!-- Outer border -->
  <rect x="0.5" y="0.5" width="279" height="43" rx="6" ry="6" fill="none" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>
</svg>'''

# --- Unknown / Not Validated badge (greyed logo, gray right panel) ---
unknown_svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="260" height="44" viewBox="0 0 260 44">
  <defs>
    <linearGradient id="bg-left-unk" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#1a1a24"/>
      <stop offset="100%" stop-color="#121218"/>
    </linearGradient>
    <linearGradient id="bg-right-unk" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#6b7280"/>
      <stop offset="100%" stop-color="#4b5563"/>
    </linearGradient>
    <filter id="grey-muted">
      <feColorMatrix type="saturate" values="0"/>
      <feComponentTransfer>
        <feFuncR type="linear" slope="0.5" intercept="0.17"/>
        <feFuncG type="linear" slope="0.5" intercept="0.17"/>
        <feFuncB type="linear" slope="0.5" intercept="0.17"/>
      </feComponentTransfer>
    </filter>
  </defs>
  <!-- Left panel: scFAIR branding (greyed) -->
  <rect x="0" y="0" width="120" height="44" rx="6" ry="6" fill="url(#bg-left-unk)"/>
  <rect x="114" y="0" width="6" height="44" fill="url(#bg-left-unk)"/>
  <!-- Right panel: NOT VALIDATED -->
  <rect x="120" y="0" width="140" height="44" rx="6" ry="6" fill="url(#bg-right-unk)"/>
  <rect x="120" y="0" width="6" height="44" fill="url(#bg-right-unk)"/>
  <!-- scFAIR logo (greyscale + muted) -->
  <svg x="2" y="1" width="50" height="42" viewBox="90 90 790 760">
    <g filter="url(#grey-muted)">
{paths_lines}
    </g>
  </svg>
  <!-- scFAIR text (greyed) -->
  <text x="85" y="28" font-family="Arial, Helvetica, sans-serif" font-size="15" font-weight="bold" fill="#999" text-anchor="middle">
    <tspan fill="#888">sc</tspan><tspan fill="#aaa">FAIR</tspan>
  </text>
  <!-- NOT VALIDATED text -->
  <text x="190" y="28" font-family="Arial, Helvetica, sans-serif" font-size="12" font-weight="bold" fill="white" text-anchor="middle" letter-spacing="0.5">NOT VALIDATED</text>
  <!-- Outer border -->
  <rect x="0.5" y="0.5" width="259" height="43" rx="6" ry="6" fill="none" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>
</svg>'''

# Write the badge files
with open('src/app/assets/images/scfair_badge_compliant.svg', 'w') as f:
    f.write(compliant_svg)
print("Written: scfair_badge_compliant.svg")

with open('src/app/assets/images/scfair_badge_noncompliant.svg', 'w') as f:
    f.write(noncompliant_svg)
print("Written: scfair_badge_noncompliant.svg")

with open('src/app/assets/images/scfair_badge_unknown.svg', 'w') as f:
    f.write(unknown_svg)
print("Written: scfair_badge_unknown.svg")

print("\nAll badge SVGs generated successfully!")
