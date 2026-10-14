"""Baked plush occlusion (moku-look-v2.md step 2): ambient occlusion and the darker creases (the neck, the ear roots,
where the arms meet the body, between the toes) computed per vertex by ray casting at rest, then painted into each felt
material's own UV layout and multiplied into its colour texture. The app reads ordinary colour textures, so it costs
nothing at runtime.

A species calls `relayout` for materials whose parts share UV space (each part a UV sphere), so every face has its own
texels, then `vertex_occlusion`, then `paint` per material, and multiplies the result into its albedo with `shade`.
Images use Blender's pixel order (row 0 at v = 0).
"""
import math,random
import bpy
import numpy as np
from mathutils.bvhtree import BVHTree

def material_faces(mesh,names):
    """Indices of the faces whose material is one of `names`."""
    slots={i for i,m in enumerate(mesh.data.materials) if m and m.name in names}
    return [p.index for p in mesh.data.polygons if p.material_index in slots]

def relayout(mesh,faces,margin=.006):
    """Smart-projects `faces` into their own non-overlapping 0..1 layout with one texel density. Other faces keep
    their UVs."""
    import bmesh
    bpy.ops.object.select_all(action='DESELECT');mesh.select_set(True);bpy.context.view_layer.objects.active=mesh
    bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_mode(type='FACE');bpy.ops.mesh.select_all(action='DESELECT')
    bm=bmesh.from_edit_mesh(mesh.data);bm.faces.ensure_lookup_table()
    for i in faces:bm.faces[i].select_set(True)
    bmesh.update_edit_mesh(mesh.data)
    bpy.ops.uv.smart_project(angle_limit=math.radians(66),island_margin=margin)
    bpy.ops.uv.pack_islands(rotate=True,margin=margin)  # smart project leaves two thirds of the square empty
    bpy.ops.mesh.select_all(action='DESELECT');bpy.ops.object.mode_set(mode='OBJECT')

def vertex_occlusion(mesh,receivers,occluders,rays=72,distance=.12,seed=7):
    """Occlusion per vertex (1 open, 0 closed) for vertex indices `receivers`, from the faces `occluders`: cosine-weighted
    rays over the hemisphere, nearer hits counting more, so a crease reads darker than a broad overhang."""
    me=mesh.data
    co=[v.co.copy() for v in me.vertices]
    tree=BVHTree.FromPolygons(co,[tuple(me.polygons[i].vertices) for i in occluders])
    directions=[]
    for i in range(rays):  # a Fibonacci spiral over the cosine-weighted disc: even, no clumps
        a=(i+.5)/rays;r=math.sqrt(a);phi=i*2.399963
        directions.append((r*math.cos(phi),r*math.sin(phi),math.sqrt(1-a)))
    rng=random.Random(seed);ao=np.ones(len(co))
    for vi in receivers:
        n=me.vertices[vi].normal
        if n.length<.5:continue
        t=n.orthogonal().normalized();b=n.cross(t);turn=rng.uniform(0,2*math.pi);c,s=math.cos(turn),math.sin(turn)
        t,b=t*c+b*s,b*c-t*s
        origin=co[vi]+n*.0015;blocked=0.0
        for x,y,z in directions:
            hit=tree.ray_cast(origin,t*x+b*y+n*z,distance)
            if hit[0] is not None:blocked+=(1-hit[3]/distance)**1.5
        ao[vi]=1-blocked/rays
    return ao

def paint(mesh,faces,values,size,wrap=False):
    """Paints per-vertex `values` over `faces` into a size×size image in UV space (barycentric), then grows the painted
    texels outward so filtering never reaches unpainted ones. `wrap` repaints triangles that run past u = 1 at u - 1 (a
    spherical layout whose seam was moved right by one)."""
    me=mesh.data;me.calc_loop_triangles();uv=me.uv_layers.active.data;wanted=set(faces)
    out=np.zeros((size,size));weight=np.zeros((size,size))
    for tri in me.loop_triangles:
        if tri.polygon_index not in wanted:continue
        p=np.array([uv[l].uv[:] for l in tri.loops])*size-.5;val=values[list(tri.vertices)]
        for shift in ([0,-size] if wrap and p[:,0].max()>size-.5 else [0]):
            q=p+[shift,0]
            x0,y0=np.floor(q.min(axis=0)).astype(int);x1,y1=np.ceil(q.max(axis=0)).astype(int)
            x0,y0=max(x0,0),max(y0,0);x1,y1=min(x1,size-1),min(y1,size-1)
            if x1<x0 or y1<y0:continue
            xs,ys=np.meshgrid(np.arange(x0,x1+1),np.arange(y0,y1+1))
            (ax,ay),(bx,by),(cx,cy)=q
            det=(by-cy)*(ax-cx)+(cx-bx)*(ay-cy)
            if abs(det)<1e-12:continue
            w0=((by-cy)*(xs-cx)+(cx-bx)*(ys-cy))/det;w1=((cy-ay)*(xs-cx)+(ax-cx)*(ys-cy))/det;w2=1-w0-w1
            inside=(w0>=-.02)&(w1>=-.02)&(w2>=-.02)
            if not inside.any():continue
            v=np.clip(w0,0,1)*val[0]+np.clip(w1,0,1)*val[1]+np.clip(w2,0,1)*val[2]
            v/=np.clip(w0,0,1)+np.clip(w1,0,1)+np.clip(w2,0,1)
            out[ys[inside],xs[inside]]+=v[inside];weight[ys[inside],xs[inside]]+=1
    painted=weight>0;out[painted]/=weight[painted]
    for _ in range(12):  # grow islands by a pixel at a time
        if painted.all():break
        acc=np.zeros_like(out);cnt=np.zeros_like(out)
        for dy,dx in [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,1),(-1,1),(1,-1)]:
            acc+=np.roll(np.roll(out*painted,dy,0),dx,1);cnt+=np.roll(np.roll(painted.astype(float),dy,0),dx,1)
        grow=(~painted)&(cnt>0);out[grow]=acc[grow]/cnt[grow];painted=painted|grow
    out[~painted]=1
    return out

def shade(rgb,ao,strength=.85,crease=(.66,.52,.44)):
    """Multiplies occlusion into sRGB colour `rgb` (HxWx3): open felt keeps its colour; occluded felt goes toward a warm
    brown, as light dims inside wool rather than turning grey."""
    k=(1-strength*(1-np.clip(ao,0,1)))[...,None]
    return rgb*(k+(1-k)*np.array(crease))

def save(name,path,rgb):
    """Writes sRGB `rgb` (HxWx3, Blender row order) as a PNG through an image named `name`, replacing its pixels."""
    h,w=rgb.shape[:2]
    img=bpy.data.images.get(name) or bpy.data.images.new(name,width=w,height=h,alpha=False)
    if tuple(img.size)!=(w,h):img.scale(w,h)
    rgba=np.ones((h,w,4),dtype=np.float32);rgba[...,:3]=np.clip(rgb,0,1)
    img.pixels.foreach_set(rgba.ravel());img.filepath_raw=str(path);img.file_format='PNG';img.save()
    return img
