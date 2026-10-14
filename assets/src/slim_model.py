"""Slims a companion's exported model, after the export:

- Sparse blend shapes: Blender's USD export lists every point in every blend shape (an index and an offset for each of
  the mesh's points, 80 shapes deep), though most shapes move a few hundred points. This keeps only the points a shape
  moves (any offset that isn't exactly zero), as UsdSkel allows; the app reads the same deltas
  (`MeshResource.Part.blendShapeOffsets` hands back one per point, zero where none is listed).
- Stand-ins: textures the app reads from character/ (materials.json names them), such as the fuzz shell's (fuzz.py),
  are replaced inside the package by a 4×4 half see-through copy, so they ship once. The model's copy keeps the
  material see-through; the app draws the colour and the fibres from the loose file (the same look as with a full
  copy; single fringe pixels differ).

Run inside Blender (for pxr), or call `slim(path, stand_ins)` after the export:
  Blender --background --factory-startup --python assets/src/slim_model.py -- assets/character/moku_bunny.usdz"""
from pathlib import Path
import os, shutil, struct, sys, tempfile, zipfile, zlib
import numpy as np
from pxr import Usd, UsdSkel, UsdUtils, Sdf, Vt


def _png(width, height, rgba):
    def chunk(kind, data): return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\x00' + bytes(rgba) * width for _ in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
STAND_IN = _png(4, 4, (255, 255, 255, 128))  # half see-through, so the material stays see-through on import


def slim(path, stand_ins=()):
    """Rewrites the package at `path` in place. Returns (offsets before, offsets after)."""
    path = Path(path).resolve(); before = after = 0
    with tempfile.TemporaryDirectory(prefix='moku-sparse-') as tmp:
        folder = Path(tmp).resolve()
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if not (folder / entry.filename).resolve().is_relative_to(folder): raise ValueError('Unsafe USD package member')
            root = folder / archive.namelist()[0]; archive.extractall(folder)
        stage = Usd.Stage.Open(str(root))
        for prim in stage.Traverse():
            if not prim.IsA(UsdSkel.BlendShape): continue
            shape = UsdSkel.BlendShape(prim); offsets = np.array(shape.GetOffsetsAttr().Get())
            indices = shape.GetPointIndicesAttr().Get(); indices = np.array(indices) if indices is not None and len(indices) else np.arange(len(offsets))
            normals = shape.GetNormalOffsetsAttr().Get(); normals = np.array(normals) if normals is not None and len(normals) else None
            moved = np.nonzero(np.any(offsets != 0, axis=1) | (np.any(normals != 0, axis=1) if normals is not None else False))[0]
            if len(moved) == 0: moved = np.array([0])  # keep the shape valid
            before += len(offsets); after += len(moved)
            shape.GetOffsetsAttr().Set(Vt.Vec3fArray.FromNumpy(offsets[moved].astype(np.float32)))
            shape.GetPointIndicesAttr().Set(Vt.IntArray.FromNumpy(indices[moved].astype(np.int32)))
            if normals is not None: shape.GetNormalOffsetsAttr().Set(Vt.Vec3fArray.FromNumpy(normals[moved].astype(np.float32)))
        # Export to a fresh file (saving a crate file in place appends), beside the textures so they're packaged.
        fresh = folder / 'fresh'; fresh.mkdir()
        if (folder / 'textures').is_dir(): shutil.copytree(folder / 'textures', fresh / 'textures')
        for name in stand_ins:
            texture = fresh / 'textures' / name
            if texture.exists(): texture.write_bytes(STAND_IN)
        layer = fresh / root.name
        if not stage.GetRootLayer().Export(str(layer)): raise RuntimeError('USD export failed')
        packed = folder / 'sparse.usdz'
        if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(layer)), str(packed)): raise RuntimeError('USDZ repack failed')
        os.replace(packed, path)
    return before, after


if __name__ == '__main__':
    for p in sys.argv[sys.argv.index('--') + 1:]:
        size = os.path.getsize(p); counts = slim(p)
        print('SLIM', Path(p).name, counts, f'{size / 1e6:.1f} MB -> {os.path.getsize(p) / 1e6:.2f} MB')
