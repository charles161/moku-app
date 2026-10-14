"""Slim Moku's animation clips: keep only what the app reads from them.

Each clip in character/anims is exported with the whole character (a 19,656-point mesh, 80 blend shapes, 13
materials and their textures), about 23 MB. The app only takes two things from a clip: the skeleton animation and
the face (blend-shape weight) track, after checking the clip's skeleton against the base character's (joint names,
parents and inverse bind poses). Loading a clip loaded a whole extra character.

This keeps the Skeleton and the SkelAnimation prims exactly as exported, cuts the skinned mesh down to the few faces
that still touch every joint and every blend shape's most-moved point (so the skin binding and all blend shapes
survive, with the same names in the same order), and drops normals, UVs, part masks, material subsets, materials
and textures. Nothing about how Moku looks or moves changes: the base character is untouched, and the animation
data in each clip is the same.

Run inside Blender (for pxr):
  Blender --background --factory-startup --python assets/src/slim_clips.py -- assets/character/anims/*.usdz"""
from pathlib import Path
import os, sys, tempfile, zipfile
import numpy as np
from pxr import Usd, UsdSkel, UsdGeom, UsdUtils, Sdf, Vt, Gf

# What a slimmed skinned mesh keeps; every other property is removed.
KEEP = {'points', 'faceVertexCounts', 'faceVertexIndices', 'extent', 'orientation', 'doubleSided', 'subdivisionScheme', 'purpose',
        'visibility', 'xformOpOrder', 'primvars:skel:jointIndices', 'primvars:skel:jointWeights', 'primvars:skel:geomBindTransform',
        'primvars:skel:skinningMethod', 'skel:blendShapes', 'skel:skeleton', 'skel:blendShapeTargets', 'skel:joints'}
ALREADY_SLIM = 4000  # points: a mesh this small has been slimmed already


def slim_mesh(stage, mesh_prim):
    mesh = UsdGeom.Mesh(mesh_prim); binding = UsdSkel.BindingAPI(mesh_prim)
    points = np.array(mesh.GetPointsAttr().Get()); counts = np.array(mesh.GetFaceVertexCountsAttr().Get()); indices = np.array(mesh.GetFaceVertexIndicesAttr().Get())
    if len(points) <= ALREADY_SLIM: return None
    ends = np.cumsum(counts); starts = ends - counts
    face_of_corner = np.repeat(np.arange(len(counts)), counts)
    def face_touching(vertex):
        corner = int(np.argmax(indices == vertex)); return int(face_of_corner[corner])
    joint_indices = np.array(binding.GetJointIndicesPrimvar().Get()); joint_weights = np.array(binding.GetJointWeightsPrimvar().Get())
    width = binding.GetJointIndicesPrimvar().GetElementSize(); ji = joint_indices.reshape(-1, width); jw = joint_weights.reshape(-1, width)
    keep_faces = set()
    for joint in np.unique(ji[jw > 0]):  # every joint that skins the mesh still skins it
        vertex = int(np.argwhere((ji == joint) & (jw > 0))[0][0]); keep_faces.add(face_touching(vertex))
    targets = binding.GetBlendShapeTargetsRel().GetTargets(); shapes = []
    for path in targets:  # and every blend shape keeps a point that it moves
        shape = UsdSkel.BlendShape(stage.GetPrimAtPath(path)); offsets = np.array(shape.GetOffsetsAttr().Get())
        pidx = shape.GetPointIndicesAttr().Get(); pidx = np.array(pidx) if pidx is not None and len(pidx) else None
        shapes.append((shape, offsets, pidx))
        if len(offsets) == 0: continue
        best = int(np.argmax(np.linalg.norm(offsets, axis=1)))
        keep_faces.add(face_touching(int(pidx[best]) if pidx is not None else best))
    faces = np.array(sorted(keep_faces))
    corners = np.concatenate([np.arange(starts[f], ends[f]) for f in faces])
    kept = np.unique(indices[corners]); remap = -np.ones(len(points), dtype=np.int64); remap[kept] = np.arange(len(kept))
    mesh.GetPointsAttr().Set(Vt.Vec3fArray.FromNumpy(points[kept].astype(np.float32)))
    mesh.GetFaceVertexCountsAttr().Set(Vt.IntArray.FromNumpy(counts[faces].astype(np.int32)))
    mesh.GetFaceVertexIndicesAttr().Set(Vt.IntArray.FromNumpy(remap[indices[corners]].astype(np.int32)))
    binding.GetJointIndicesPrimvar().Set(Vt.IntArray.FromNumpy(ji[kept].reshape(-1).astype(np.int32)))
    binding.GetJointWeightsPrimvar().Set(Vt.FloatArray.FromNumpy(jw[kept].reshape(-1).astype(np.float32)))
    for shape, offsets, pidx in shapes:
        normals = shape.GetNormalOffsetsAttr().Get(); normals = np.array(normals) if normals is not None and len(normals) else None
        if pidx is None:  # dense: one offset per point
            mask = kept; new_idx = None
        else:
            mask = np.nonzero(np.isin(pidx, kept))[0]; new_idx = remap[pidx[mask]]
        new_offsets = offsets[mask] if len(offsets) else offsets
        if len(new_offsets) == 0:  # never expected (every shape keeps a point), but keep the shape valid
            new_offsets = np.zeros((1, 3)); new_idx = np.array([0])
        shape.GetOffsetsAttr().Set(Vt.Vec3fArray.FromNumpy(np.asarray(new_offsets, dtype=np.float32)))
        if new_idx is not None: shape.GetPointIndicesAttr().Set(Vt.IntArray.FromNumpy(np.asarray(new_idx, dtype=np.int32)))
        if normals is not None:
            shape.GetNormalOffsetsAttr().Set(Vt.Vec3fArray.FromNumpy(np.asarray(normals[mask] if len(normals) == len(offsets) else normals[:len(new_offsets)], dtype=np.float32)))
    for prop in list(mesh_prim.GetPropertyNames()):
        if prop not in KEEP and not prop.startswith('xformOp:'): mesh_prim.RemoveProperty(prop)
    for child in list(mesh_prim.GetChildren()):
        if child.GetTypeName() == 'GeomSubset': stage.RemovePrim(child.GetPath())
    return len(points), len(kept), len(faces)


def slim_clip(path):
    """Slim one clip file in place. Returns (points before, points after, faces after), or None if already slim."""
    path = Path(path).resolve()
    with tempfile.TemporaryDirectory(prefix='moku-slim-') as tmp:
        folder = Path(tmp).resolve()
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if not (folder / entry.filename).resolve().is_relative_to(folder): raise ValueError('Unsafe USD package member')
            root = folder / archive.namelist()[0]; archive.extractall(folder)
        stage = Usd.Stage.Open(str(root)); result = None
        meshes = [p for p in stage.Traverse() if p.GetTypeName() == 'Mesh' and UsdSkel.BindingAPI(p).GetSkeletonRel().GetTargets()]
        for prim in meshes:
            if prim.IsValid():
                result = slim_mesh(stage, prim) or result
        if result is None: return None
        for material in [p.GetPath() for p in stage.Traverse() if p.GetTypeName() == 'Material']:  # no materials, so no textures get packaged
            stage.RemovePrim(material)
        # Export to a fresh file: saving a crate file in place appends, leaving the old data in it.
        fresh = folder / 'fresh'; fresh.mkdir(); layer = fresh / root.name
        if not stage.GetRootLayer().Export(str(layer)): raise RuntimeError('USD export failed')
        packed = folder / 'slim.usdz'
        if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(layer)), str(packed)): raise RuntimeError('USDZ repack failed')
        os.replace(packed, path)
    return result


if __name__ == '__main__':
    for p in sys.argv[sys.argv.index('--') + 1:]:
        before = os.path.getsize(p); result = slim_clip(p)
        print('SLIM', Path(p).name, result, f'{before / 1e6:.1f} MB -> {os.path.getsize(p) / 1e6:.2f} MB')
