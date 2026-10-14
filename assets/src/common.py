import bpy, math, json, sys, random
from pathlib import Path
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]
random.seed(42)

def reset():
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
    for d in list(bpy.data.materials): bpy.data.materials.remove(d)

def mat(name,color,rough=.65,metal=0,emission=None):
    m=bpy.data.materials.new(name); m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF'); p.inputs['Base Color'].default_value=(*color,1)
    p.inputs['Roughness'].default_value=rough; p.inputs['Metallic'].default_value=metal
    if emission:
        p.inputs['Emission Color'].default_value=(*color,1); p.inputs['Emission Strength'].default_value=emission
    return m

def finish(o,name,material):
    o.name=name
    if material:o.data.materials.append(material)
    if o.type=='MESH':
        for p in o.data.polygons:p.use_smooth=True
    return o

def sphere(name,loc,scale,material,seg=32,rings=20):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=seg,ring_count=rings,location=loc)
    o=bpy.context.object; o.scale=scale; bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    return finish(o,name,material)

def tube(name,points,radius,material,res=8):
    bpy.ops.object.select_all(action='DESELECT')
    c=bpy.data.curves.new(name,'CURVE'); c.dimensions='3D'; c.resolution_u=12
    s=c.splines.new('BEZIER');s.bezier_points.add(len(points)-1)
    for p,co in zip(s.bezier_points,points):p.co=co;p.handle_left_type='AUTO';p.handle_right_type='AUTO'
    c.bevel_depth=radius;c.bevel_resolution=2;c.resolution_u=res
    o=bpy.data.objects.new(name,c);bpy.context.collection.objects.link(o)
    bpy.context.view_layer.objects.active=o;o.select_set(True)
    bpy.ops.object.convert(target='MESH');o=bpy.context.object;o.select_set(False)
    return finish(o,name,material)

def cylinder(name,loc,radius,depth,material,vertices=24):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices,radius=radius,depth=depth,location=loc)
    return finish(bpy.context.object,name,material)

def link_between(name,a,b,r,material):
    a,b=Vector(a),Vector(b);o=cylinder(name,(a+b)/2,r,(b-a).length,material)
    o.rotation_euler=(b-a).to_track_quat('Z','Y').to_euler();return o

def select(objects):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objects:o.select_set(True)
    if objects:bpy.context.view_layer.objects.active=objects[0]

def triangles(objects):return sum(sum(len(p.vertices)-2 for p in o.data.polygons) for o in objects if o.type=='MESH')

def export(path,objects,animation=False):
    select(objects)
    bpy.ops.wm.usd_export(filepath=str(path),selected_objects_only=True,export_animation=animation,export_hair=False,export_armatures=True,export_shapekeys=True,only_deform_bones=False,export_materials=True,generate_preview_surface=True,generate_materialx_network=False,export_textures_mode='NEW',convert_orientation=True,export_global_forward_selection='NEGATIVE_Z',export_global_up_selection='Y',root_prim_path='/Moku' if 'character' in str(path) else '/World',export_lights=False,export_cameras=False,export_subdivision='IGNORE',triangulate_meshes=False,meters_per_unit=1.0)
    if animation:
        from pin_animation_bounds import pin_animation_bounds
        pin_animation_bounds(path)
        # A clip only lends the app its skeleton animation and face track: drop the rest of the character.
        from slim_clips import slim_clip
        slim_clip(path)

def studio(target=(0,0,.47),distance=2.7,ortho=1.35,world_color=(.19,.16,.13)):
    scene=bpy.context.scene;scene.render.engine='CYCLES';scene.cycles.samples=32
    scene.cycles.use_denoising=True;scene.render.resolution_x=900;scene.render.resolution_y=900;scene.render.resolution_percentage=100
    scene.render.film_transparent=True;scene.world.color=world_color
    scene.view_settings.view_transform='AgX'
    bpy.ops.object.camera_add(location=(distance*.35,-distance,distance*.52));cam=bpy.context.object
    cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=ortho;scene.camera=cam
    for name,loc,power,size,col in [('Key',(-2,-3,4),250,3,(1,.84,.7)),('Fill',(2,-1,2),150,3,(.8,.9,1)),('Rim',(0,2,3),300,2,(1,.83,.58))]:
        bpy.ops.object.light_add(type='AREA',location=loc);l=bpy.context.object;l.name=name;l.data.energy=power;l.data.shape='DISK';l.data.size=size;l.data.color=col;l.rotation_euler=(Vector(target)-l.location).to_track_quat('-Z','Y').to_euler()
    return cam

def render(path):
    bpy.context.scene.render.filepath=str(path);bpy.ops.render.render(write_still=True)
