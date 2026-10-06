#!/usr/bin/env python3
"""Trace a flat raster asset to a new workspace SVG, preserving the source PNG."""
import argparse
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image
import vtracer


def vectorize(source, output, workspace, force=False, mode='spline'):
    workspace = workspace.resolve(strict=True)
    source = source.resolve(strict=True)
    output = output.resolve()
    manifest = output.with_suffix('.svg.json')
    for path in (source, output, manifest):
        if not path.is_relative_to(workspace):
            raise ValueError('asset paths must stay inside the workspace')
    if output.suffix.lower() != '.svg':
        raise ValueError('output must end in .svg')
    if output.exists() or manifest.exists():
        raise ValueError('output or manifest already exists; choose a new name')
    if source.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('source exceeds 32 MiB')
    data = source.read_bytes()
    with Image.open(io.BytesIO(data)) as image:
        if image.format not in ('PNG', 'JPEG', 'WEBP') or getattr(image, 'is_animated', False):
            raise ValueError('source must be a still PNG, JPEG or WebP')
        width, height = image.size
        if width > 4096 or height > 4096 or width * height > 8_000_000:
            raise ValueError('source exceeds raster size limits')
        image.load()
        image = image.convert('RGBA')
        sample = image.copy()
        sample.thumbnail((128, 128))
        colors = Counter(tuple(v // 16 for v in pixel) for pixel in sample.get_flattened_data())
        flatness = sum(count for _, count in colors.most_common(16)) / (sample.width * sample.height)
        if flatness < .9 and not force:
            raise ValueError(f'source is unsuitable for flat tracing ({flatness:.1%} dominant-color coverage); retain the raster or explicitly use --force')
        # Trace decoded pixels, so decoder limits apply before native processing.
        svg = vtracer.convert_pixels_to_svg(list(image.get_flattened_data()), (width, height),
            colormode='color', hierarchical='stacked', mode=mode,
            filter_speckle=4, color_precision=6, layer_difference=16,
            path_precision=2)
    if len(svg.encode()) > 4 * 1024 * 1024:
        raise ValueError('trace exceeds 4 MiB; retain the raster')
    root = ET.fromstring(svg)
    root.set('viewBox', f'0 0 {width} {height}')
    ET.register_namespace('', 'http://www.w3.org/2000/svg')
    svg = ET.tostring(root, encoding='unicode')
    metadata = {'source': str(source.relative_to(workspace)),
        'source_sha256': hashlib.sha256(data).hexdigest(),
        'svg_sha256': hashlib.sha256(svg.encode()).hexdigest(),
        'width': width, 'height': height, 'dominant_color_coverage': flatness,
        'tracer': 'vtracer', 'mode': mode, 'lossless': False}
    # Exclusive creation preserves existing assets, including concurrent writers.
    with output.open('x') as stream:
        stream.write(svg)
    try:
        with manifest.open('x') as stream:
            stream.write(json.dumps(metadata, indent=2) + '\n')
    except Exception:
        output.unlink()
        raise
    return metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--workspace', type=Path, default=Path.cwd())
    parser.add_argument('--force', action='store_true', help='Explicitly trace a non-flat image; inspect quality afterward')
    parser.add_argument('--mode', choices=['spline', 'polygon', 'none'], default='spline', help='Use none for pixel art')
    args = parser.parse_args()
    try:
        print(json.dumps(vectorize(args.source, args.output, args.workspace, args.force, args.mode), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, f'vectorize_asset: {error}\n')
