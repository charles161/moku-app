"""A felt's fuzzy edge (moku-look-v2.md step 4): one thin see-through shell over the felt, so the silhouette softens
into a few pixels of fibre instead of a clean CG line. The shell is the felt's own faces copied a few millimetres out
along their normals, inside the same skinned mesh: it keeps every vertex group and every shape key (each key's shell
vertex moves exactly as the felt under it), so skinning and the face morphs (on the GPU or the CPU) carry it with no
runtime code. Its material is the felt's own with an alpha channel of fibre noise, made in 3D at rest, so the fibres
are one size on every part whatever its UV density. Face-on the shell is the felt's own colour over the felt and
barely shows; at the silhouette it stands past the edge as a soft, broken fringe.

The alpha never reaches zero on a face that's kept: the fringe stays one piece with the body (the audits count every
pixel with any alpha as silhouette and fail on islands). Faces a species wants bare (Moku's face, where the eyes, the
brows and the blush live) are left out, with a fade into them.
"""
from mathutils.kdtree import KDTree
import bmesh
import bpy
import numpy as np
import occlusion as oc

def _hash(i,j,k,seed):
    h=(i*73856093)^(j*19349663)^(k*83492791)^(seed*2654435761)
    h=h&0xffffffff;h=((h>>16)^h)*0x45d9f3b&0xffffffff;h=((h>>16)^h)*0x45d9f3b&0xffffffff;h=(h>>16)^h
    return (h&0xffffff)/float(0xffffff)

def value_noise(p,cell,seed):
    """Smooth value noise in 0..1 at points `p` (N×3), one random value per `cell`-sized lattice point."""
    q=p/cell;base=np.floor(q).astype(np.int64);f=q-base;f=f*f*(3-2*f)
    out=np.zeros(len(p))
    for dx in (0,1):
        for dy in (0,1):
            for dz in (0,1):
                w=(f[:,0] if dx else 1-f[:,0])*(f[:,1] if dy else 1-f[:,1])*(f[:,2] if dz else 1-f[:,2])
                out+=w*_hash(base[:,0]+dx,base[:,1]+dy,base[:,2]+dz,seed)
    return out

def fibres(p,cell,seed):
    """Fibre density at points `p`: two octaves of value noise, contrast stretched to about 0..1."""
    n=.62*value_noise(p,cell,seed)+.38*value_noise(p,cell*.45,seed+1)
    return np.clip((n-.5)*2.4+.5,0,1)

def smooth(a,b,x):
    t=np.clip((np.asarray(x,dtype=float)-a)/(b-a),0,1);return t*t*(3-2*t)

def clear_of(mesh,names,near,far):
    """Per vertex 0..1: 0 within `near` of any vertex of the materials `names` (felt the shell must not cover, such
    as pads lying on a foot or an inner ear in its cup), 1 beyond `far`."""
    me=mesh.data;slots={i for i,m in enumerate(me.materials) if m and m.name in names}
    points={v for p in me.polygons if p.material_index in slots for v in p.vertices}
    tree=KDTree(len(points))
    for i in points:tree.insert(me.vertices[i].co,i)
    tree.balance()
    return smooth(near,far,[tree.find(v.co)[2] for v in me.vertices])

def silhouette_band(mesh,front=(0,-1,0),near=45,far=150,soft=10):
    """Per vertex 0..1: where the felt can be the outline. Faces turned toward the camera (within `near` degrees of
    `front`, the way the character faces) or away from it (beyond `far`), and the underside it sits on, are only
    outline when it turns further than it does; they get no shell, which halves the shell's pixels. Fades over `soft`."""
    n=np.array([v.normal[:] for v in mesh.data.vertices]);angle=np.degrees(np.arccos(np.clip(n@np.array(front,dtype=float),-1,1)))
    return smooth(near,near+soft,angle)*(1-smooth(far-soft,far,angle))*(1-smooth(.6,.8,-n[:,2]))

def grow(mesh,shells,seed=11):
    """Adds one fuzz shell per entry of `shells`, a list of dicts:
      base: the felt material whose faces get a shell;  name: the shell's material name;
      image: the RGBA image name;  path: where it's saved;  rgb: the felt's sRGB colour texture (H×W×3, Blender rows);
      wrap: the layout wraps past u = 1 (oc.paint);  offset: how far out (metres);  cell: fibre size (metres);
      alpha: (low, high) opacity of the fibres;  weight: optional per-vertex 0..1 (0 drops the face, fades between);
      lumps: 0..1, how much the offset varies (in `lump_cell`-sized tufts).
    Returns the shell's triangle count."""
    me=mesh.data;added=0
    rest=np.array([v.co[:] for v in me.vertices]);normals=np.array([v.normal[:] for v in me.vertices])
    for spec in shells:
        faces=oc.material_faces(mesh,[spec['base']])
        weight=spec.get('weight');weight=np.ones(len(rest)) if weight is None else np.asarray(weight,dtype=float)
        faces=[f for f in faces if max(weight[v] for v in me.polygons[f].vertices)>.02]
        size=spec['rgb'].shape[0]
        # Each texel's 3D place at rest, painted through the felt's own UVs, then the fibres there.
        where=np.stack([oc.paint(mesh,faces,rest[:,k],size,wrap=spec.get('wrap',False)) for k in range(3)],axis=-1)
        fade=oc.paint(mesh,faces,weight,size,wrap=spec.get('wrap',False))
        low,high=spec['alpha']
        alpha=(low+(high-low)*fibres(where.reshape(-1,3),spec['cell'],seed).reshape(size,size))*np.clip(fade,0,1)
        rgba=np.ones((size,size,4),dtype=np.float32);rgba[...,:3]=np.clip(spec['rgb'],0,1);rgba[...,3]=np.clip(alpha,.02,1)
        img=bpy.data.images.get(spec['image']) or bpy.data.images.new(spec['image'],width=size,height=size,alpha=True)
        img.alpha_mode='STRAIGHT';img.pixels.foreach_set(rgba.ravel());img.filepath_raw=str(spec['path']);img.file_format='PNG';img.save()
        # The shell's material: the felt's own (sheen, normal map) with this colour and its alpha.
        base=bpy.data.materials[spec['base']];shell=base.copy();shell.name=spec['name']
        nodes=shell.node_tree.nodes;bsdf=nodes.get('Principled BSDF')
        tex=next(l.from_node for l in shell.node_tree.links if l.to_node==bsdf and l.to_socket.name=='Base Color')
        tex.image=img
        shell.node_tree.links.new(tex.outputs['Alpha'],bsdf.inputs['Alpha'])
        if hasattr(shell,'surface_render_method'):shell.surface_render_method='BLENDED'
        me.materials.append(shell);slot=len(me.materials)-1
        # Copy the faces (vertex groups and UVs come along), then place every shape key's copy off its own felt.
        bm=bmesh.new();bm.from_mesh(me);bm.faces.ensure_lookup_table()
        before=len(bm.verts)
        made=bmesh.ops.duplicate(bm,geom=[bm.faces[i] for i in faces])
        for f in made['geom']:
            if isinstance(f,bmesh.types.BMFace):f.material_index=slot
        source={new.index:old.index for old,new in made['vert_map'].items() if isinstance(old,bmesh.types.BMVert)}
        bm.to_mesh(me);bm.free()
        new=np.arange(before,len(me.vertices));old=np.array([source[i] for i in new])
        # Lumps: the shell stands further out in some places than others, so the outline is tufted, not a parallel line.
        # Where the weight fades the shell comes down onto the felt, so an open edge of the shell never floats off it
        # (seen edge on, a floating rim would leave a stray pixel beside the silhouette).
        lumps=spec.get('lumps',0)
        height=spec['offset']*(1-lumps/2+lumps*value_noise(rest[old],spec.get('lump_cell',.02),seed+7))*np.clip(weight[old],0,1)
        push=normals[old]*height[:,None]
        flat=np.empty(len(me.vertices)*3)
        for key in me.shape_keys.key_blocks:
            key.data.foreach_get('co',flat);co=flat.reshape(-1,3)
            co[new]=co[old]+push;key.data.foreach_set('co',co.ravel())
        me.vertices.foreach_get('co',flat);co=flat.reshape(-1,3);co[new]=rest[old]+push;me.vertices.foreach_set('co',co.ravel())
        me.update()
        rest=np.array([v.co[:] for v in me.vertices]);normals=np.array([v.normal[:] for v in me.vertices])
        added+=sum(len(me.polygons[f].vertices)-2 for f in faces)
    return added
