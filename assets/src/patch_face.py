"""Rewrites Moku's smiling shapes (face_shapes.py) in the exported model, from the model's own rest points, without a
rebuild: a rebuild renumbers the body's faces and re-bakes the felt, and these shapes touch only the eyes. The same
functions build them in species_moku.morph, so a later rebuild gives the same shapes.

Run with Blender's Python (it has pxr):
  /Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 assets/src/patch_face.py [--check]

--check only reports how far the model's shapes are from face_shapes.py (0 once patched)."""
import os, shutil, sys, tempfile, zipfile
from pathlib import Path
import numpy as np
from pxr import Usd, UsdSkel, UsdUtils, Sdf, Vt
sys.path.insert(0, str(Path(__file__).resolve().parent))
import face_shapes

MODEL = Path(os.environ.get('MOKU_MODEL') or Path(__file__).resolve().parents[1] / 'character/moku_bunny.usdz')
MESH = '/Moku/Rig/Plush/Sphere'


def target(name, points, offsets):
    """The shape's offsets per face_shapes.py, for the points it moves. The catchlights keep their push back (y)."""
    out = offsets.copy()
    shape = {'eyes_happy': face_shapes.happy_eye, 'lid_smile_lower': face_shapes.smile_lower_lid}[name]
    for i, (x, y, z) in enumerate(points):
        nx, ny, nz = shape(x, y, z, 1 if x > 0 else -1)
        out[i] = (nx - x, offsets[i][1], nz - z)
    return out


def patch(path, check=False):
    with tempfile.TemporaryDirectory(prefix='moku-face-') as tmp:
        folder = Path(tmp).resolve()
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if not (folder / entry.filename).resolve().is_relative_to(folder): raise ValueError('Unsafe USD package member')
            root = folder / archive.namelist()[0]; archive.extractall(folder)
        stage = Usd.Stage.Open(str(root))
        points = np.array(stage.GetPrimAtPath(MESH).GetAttribute('points').Get())
        for name in ['eyes_happy', 'lid_smile_lower']:
            shape = UsdSkel.BlendShape(stage.GetPrimAtPath(f'{MESH}/{name}'))
            indices = np.array(shape.GetPointIndicesAttr().Get()); offsets = np.array(shape.GetOffsetsAttr().Get())
            new = target(name, points[indices], offsets)
            print(name, 'points', len(indices), 'largest change', float(np.abs(new - offsets).max()))
            if not check: shape.GetOffsetsAttr().Set(Vt.Vec3fArray.FromNumpy(new.astype(np.float32)))
        if check: return
        fresh = folder / 'fresh'; fresh.mkdir()
        if (folder / 'textures').is_dir(): shutil.copytree(folder / 'textures', fresh / 'textures')
        layer = fresh / root.name
        if not stage.GetRootLayer().Export(str(layer)): raise RuntimeError('USD export failed')
        packed = folder / 'patched.usdz'
        if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(layer)), str(packed)): raise RuntimeError('USDZ repack failed')
        os.replace(packed, path)


if __name__ == '__main__':
    patch(MODEL, check='--check' in sys.argv)
