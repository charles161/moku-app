"""The parts of Moku's home (docs/specs/home.md): palette, helpers and every piece of furniture, garden and light.

Every part is built in its own frame: Blender units, z up, standing on z = 0, centred on x = 0, its front facing −y
(towards the camera). Wall pieces hang from their back at y = 0. Moku is about 1.07 tall sitting."""
import math, random
import bpy, bmesh
from mathutils import Vector, Matrix
from common import finish, sphere, tube, cylinder, link_between, select, triangles, export

rng = random.Random(11)

# ── Palette: name → (hex sRGB, roughness, felt, glow). Felt carries Moku's plush normal map; glow is emissive.
PALETTE = {
    # Land
    'Grass felt': ('7FA35B', .95, True, False), 'Grass deep': ('5E8A45', .95, True, False), 'Grass light': ('A6C47A', .95, True, False),
    'Earth face': ('FFFFFF', .96, False, False),  # textured: the strata of the cutaway
    'Earth chamber': ('5A3D2B', .97, True, False), 'Earth dark': ('3E2A1E', .97, True, False), 'Earth side': ('6B4A33', .96, True, False),
    'Pebble': ('A89A89', .8, False, False), 'Root': ('4A3222', .9, True, False), 'Stone': ('9C9489', .85, False, False),
    # Wood
    'Honey wood': ('C28A55', .7, False, False), 'Walnut': ('7A4E2D', .72, False, False), 'Plank': ('B07D4F', .75, False, False),
    'Plank dark': ('8E6340', .78, False, False), 'Bark': ('7B5536', .95, True, False), 'Bark light': ('9A7250', .95, True, False),
    'Shingle': ('9E5A3C', .85, True, False), 'Door green': ('5E8C5A', .7, False, False), 'Brass': ('D4A64A', .35, False, False),
    'Iron': ('3A3634', .6, False, False),
    # Fabric and paper
    'Plaster': ('EBDDC4', .95, True, False), 'Cream felt': ('F2E6CF', .95, True, False), 'Rust felt': ('C0643C', .95, True, False),
    'Mustard felt': ('D9A441', .95, True, False), 'Teal felt': ('4F8A8B', .95, True, False), 'Rose felt': ('D4918C', .95, True, False),
    'Indigo felt': ('4A5B84', .95, True, False), 'Sage felt': ('8FAE7E', .95, True, False), 'Plum felt': ('7E4B6B', .95, True, False),
    'Paper': ('F4ECDA', .9, False, False), 'Ink': ('3A3A48', .9, False, False), 'Cork': ('B68D5F', .95, True, False),
    'Terracotta': ('C0714B', .85, False, False), 'Ceramic white': ('F3EFE8', .45, False, False), 'Ceramic blue': ('6F8FB3', .45, False, False),
    # Food and garden
    'Carrot': ('E98A3A', .8, True, False), 'Leaf': ('5E9A45', .9, True, False), 'Leaf dark': ('3F7A3A', .9, True, False),
    'Cabbage': ('A8C98A', .9, True, False), 'Pumpkin': ('E0873A', .85, True, False), 'Petal white': ('F6F0E4', .9, True, False),
    'Petal yellow': ('F2C94C', .9, True, False), 'Petal pink': ('E7A0B0', .9, True, False), 'Petal blue': ('8FA8E0', .9, True, False),
    'Petal red': ('D65A4A', .9, True, False), 'Soil': ('5B3A28', .98, True, False), 'Bread': ('D29A5C', .9, True, False),
    'Jam red': ('B8323A', .4, False, False), 'Jam amber': ('D98E2B', .4, False, False), 'Jam green': ('7FA348', .4, False, False),
    'Jam plum': ('6E3A5E', .4, False, False), 'Glass': ('DCE8E6', .15, False, False),
    # Walls, paint and roofs: each room has its own colour, inside and out.
    'Wall sage': ('B9CBA6', .95, True, False), 'Wall cream': ('EBDDC4', .95, True, False), 'Wall butter': ('EFD89A', .95, True, False),
    'Wall rose': ('E4B7AE', .95, True, False), 'Wall teal': ('86ABA3', .95, True, False),
    'Roof teal': ('4F7E7A', .85, True, False), 'Roof terracotta': ('B8603F', .85, True, False), 'Trim': ('F4EBDD', .8, False, False),
    # Light
    'Lamp glow': ('FFD08A', .5, False, True), 'Star glow': ('FFF3C4', .5, False, True), 'Window glow': ('FFC978', .5, False, True),
}
BOOK_COLOURS = ['Rust felt', 'Mustard felt', 'Teal felt', 'Rose felt', 'Indigo felt', 'Sage felt', 'Plum felt', 'Cream felt', 'Walnut', 'Door green']


def linear(hex_):
    return tuple(((int(hex_[i:i + 2], 16) / 255) / 12.92 if int(hex_[i:i + 2], 16) / 255 <= 0.04045 else (((int(hex_[i:i + 2], 16) / 255) + 0.055) / 1.055) ** 2.4) for i in (0, 2, 4))


M = {}
def materials(root):
    """Blender materials for previews; the app takes its own from world/home/materials.json by name."""
    for name, (hex_, rough, felt, glow) in PALETTE.items():
        m = bpy.data.materials.new(name); m.use_nodes = True
        p = m.node_tree.nodes.get('Principled BSDF'); c = linear(hex_)
        p.inputs['Base Color'].default_value = (*c, 1); p.inputs['Roughness'].default_value = rough
        # No texture nodes: the app applies the felt normal map (and the strata) from materials.json, and a
        # texture here would be copied into every exported part.
        if felt: p.inputs['Sheen Weight'].default_value = .35
        if glow:
            p.inputs['Emission Color'].default_value = (*c, 1); p.inputs['Emission Strength'].default_value = 6
        M[name] = m
    return M


def material_rules():
    """world/home/materials.json: merged into runtime/materials.json by materials.py."""
    rules = []
    for name, (hex_, rough, felt, glow) in PALETTE.items():
        c = list(linear(hex_))
        r = {'name': name, 'baseTint': c + [1.0], 'roughness': rough, 'normalMapPath': 'character/plush_normal.png' if felt else None,
             'normalScale': .3 if felt else 1.0, 'normalTiling': [1, 1], 'sheenColor': [x * .22 for x in c] if felt else [0, 0, 0], 'sheenRoughness': .85}
        if glow: r['emissive'] = c; r['emissiveIntensity'] = 1.6
        if name == 'Earth face': r['baseColorTexturePath'] = 'world/home/earth_face.png'
        rules.append(r)
    return rules


# ── Shape helpers.
def rbox(name, loc, size, material, bevel=.3, segments=3):
    """A box of full `size` with softly rounded edges (bevel is a fraction of the smallest side)."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc); o = bpy.context.object; o.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel > 0:
        b = o.modifiers.new('soft', 'BEVEL'); b.width = min(size) * bevel * .5; b.segments = segments; b.limit_method = 'NONE'
        bpy.context.view_layer.objects.active = o; bpy.ops.object.modifier_apply(modifier=b.name)
    return finish(o, name, M[material] if material else None)


def ball(name, loc, radii, material, seg=20, rings=12):
    return sphere(name, loc, radii, M[material], seg, rings)


def cyl(name, loc, r, depth, material, vertices=20, rot=None):
    o = cylinder(name, loc, r, depth, M[material], vertices)
    if rot: o.rotation_euler = rot
    return o


def cone(name, loc, r1, r2, depth, material, vertices=20, rot=None):
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=r1, radius2=r2, depth=depth, location=loc)
    o = finish(bpy.context.object, name, M[material])
    if rot: o.rotation_euler = rot
    return o


def lathe(name, profile, material, segments=28):
    """A turned shape from (radius, height) points, bottom to top."""
    bm = bmesh.new(); rings = []
    for i in range(segments):
        a = 2 * math.pi * i / segments
        rings.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z)) for r, z in profile])
    for i in range(segments):
        a, b = rings[i], rings[(i + 1) % segments]
        for j in range(len(profile) - 1): bm.faces.new((a[j], b[j], b[j + 1], a[j + 1]))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(o)
    return finish(o, name, M[material])


def rod(name, a, b, r, material, vertices=10):
    return link_between(name, a, b, r, M[material])


def curve(name, points, r, material, res=6):
    return tube(name, points, r, M[material], res)


def join(name, objs):
    """One object, origin at the world origin, transforms applied."""
    objs = [o for o in objs if o is not None]
    for o in objs:
        select([o]); bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    select(objs)
    if len(objs) > 1: bpy.ops.object.join()
    o = bpy.context.object; o.name = name
    bpy.context.scene.cursor.location = (0, 0, 0); bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
    return o


PARTS = {}
MANIFEST = []
def save(out, name, objs, limit=9000, key=None):
    """Join, export to `out/name.usdz`, and keep the object hidden as a prototype for previews (under `key`)."""
    o = join(name, objs)
    # Triangulate here: RealityKit fans concave polygons (like the cutaway around each room) across their holes.
    t = o.modifiers.new('triangulate', 'TRIANGULATE'); t.quad_method = 'BEAUTY'; t.ngon_method = 'BEAUTY'; t.keep_custom_normals = True
    select([o]); bpy.context.view_layer.objects.active = o; bpy.ops.object.modifier_apply(modifier=t.name)
    export(out / (name + '.usdz'), [o]); count = triangles([o]); assert count < limit, (name, count)
    PARTS[key or name] = o; MANIFEST.append({'name': key or name, 'triangles': count})
    o.hide_render = True; o.hide_set(True)
    return o


# ── The door (stage 0).
def door_parts(out):
    # A round green door in a stone ring, with a brass knob and a little window.
    p = [cyl('door', (0, -.02, .52), .5, .08, 'Door green', 40, (math.pi / 2, 0, 0))]
    for i in range(18):
        a = math.pi * 2 * i / 18
        p.append(rbox('ring stone', (.6 * math.cos(a), -.03, .52 + .6 * math.sin(a)), (.2, .16, .15), 'Stone', .5))
        p[-1].rotation_euler.y = -a
    for x in (-.25, 0, .25): p.append(rbox('door board seam', (x, -.065, .5), (.012, .01, .8), 'Walnut', .5))
    p.append(ball('knob', (0, -.1, .5), (.05, .05, .05), 'Brass', 12, 8))
    p.append(cyl('door window', (0, -.07, .8), .1, .03, 'Window glow', 20, (math.pi / 2, 0, 0)))
    p.append(cyl('door window rim', (0, -.075, .8), .12, .02, 'Brass', 20, (math.pi / 2, 0, 0)))
    save(out, 'round_door', p)
    # A lantern on a post, glowing.
    p = [cyl('post', (0, 0, .45), .035, .9, 'Walnut', 10), rbox('arm', (.12, 0, .88), (.26, .03, .03), 'Walnut', .5)]
    p.append(rod('hook', (.24, 0, .88), (.24, 0, .8), .006, 'Iron'))
    p.append(rbox('lantern cage', (.24, 0, .71), (.12, .12, .16), 'Iron', .3))
    p.append(rbox('lantern light', (.24, 0, .71), (.1, .13, .13), 'Lamp glow', .3))
    p.append(cone('lantern cap', (.24, 0, .81), .09, .02, .06, 'Iron', 12))
    save(out, 'lantern_post', p)
    # A mailbox on a stake, and a doormat.
    p = [cyl('stake', (0, 0, .3), .025, .6, 'Walnut', 8), rbox('box', (0, 0, .64), (.14, .24, .14), 'Rust felt', .4),
         ball('box top', (0, 0, .7), (.07, .12, .05), 'Rust felt', 16, 8), rbox('flag', (.08, .05, .7), (.01, .03, .1), 'Mustard felt', .5)]
    save(out, 'mailbox', p)
    save(out, 'doormat', [rbox('mat', (0, 0, .01), (.6, .34, .02), 'Mustard felt', .4), rbox('mat edge', (0, 0, .012), (.52, .26, .022), 'Rust felt', .4)])


# ── Entry nook.
def entry_parts(out):
    p = [cyl('rug', (0, 0, .006), .45, .012, 'Rust felt', 40)]
    for i, (r, m) in enumerate([(.36, 'Mustard felt'), (.26, 'Cream felt'), (.15, 'Teal felt')]): p.append(cyl('ring', (0, 0, .008 + i * .002), r, .012, m, 40))
    save(out, 'rug_round', p)
    p = [rbox('hook board', (0, .02, 0), (.6, .04, .1), 'Walnut', .4)]
    for x in (-.2, 0, .2): p.append(rod('peg', (x, 0, 0), (x, -.1, .04), .015, 'Honey wood'))
    p.append(curve('scarf', [(-.2, -.08, .03), (-.22, -.1, -.2), (-.18, -.09, -.4)], .03, 'Rose felt'))
    p.append(ball('hat', (.2, -.1, .02), (.09, .09, .06), 'Indigo felt', 14, 8))
    save(out, 'coat_hooks', p)
    p = [rbox('bench seat', (0, 0, .26), (.6, .26, .06), 'Honey wood', .4)]
    for x in (-.24, .24): p.append(rbox('bench leg', (x, 0, .12), (.06, .22, .24), 'Honey wood', .4))
    p.append(rbox('bench cushion', (0, 0, .31), (.5, .22, .05), 'Teal felt', .6))
    save(out, 'bench', p)
    p = []
    for x in (-.06, .06):
        p.append(rbox('boot shaft', (x, 0, .1), (.08, .1, .18), 'Walnut', .6)); p.append(rbox('boot foot', (x, -.05, .03), (.08, .16, .06), 'Walnut', .7))
    save(out, 'boots', p)
    p = [cyl('stand', (0, 0, .15), .09, .3, 'Ceramic blue', 18), rod('umbrella', (0, 0, .1), (.02, 0, .62), .012, 'Walnut'),
         cone('canopy', (.02, 0, .45), .06, .02, .28, 'Rust felt', 10), curve('handle', [(.02, 0, .62), (.02, 0, .68), (.08, 0, .66)], .012, 'Walnut')]
    save(out, 'umbrella_stand', p)
    p = [rbox('sconce plate', (0, .015, 0), (.1, .03, .16), 'Brass', .5), rod('sconce arm', (0, 0, 0), (0, -.1, .03), .01, 'Brass'),
         ball('sconce bulb', (0, -.12, .06), (.045, .045, .06), 'Lamp glow', 12, 8), cone('sconce shade', (0, -.12, .1), .07, .03, .07, 'Cream felt', 14)]
    save(out, 'sconce', p)
    p = [lathe('pot', [(0, 0), (.1, 0), (.12, .16), (.13, .18), (0, .18)], 'Terracotta', 20)]
    for i in range(9):
        a = i * 2.4; t = Vector((math.cos(a) * .18, math.sin(a) * .14, .5 + .08 * (i % 3)))
        p.append(curve('frond', [(0, 0, .16), tuple(t * .5 + Vector((0, 0, .15))), tuple(t)], .02, 'Leaf' if i % 2 else 'Leaf dark'))
    save(out, 'fern', p)
    save(out, 'picture_small', frame_art(.3, .24))
    save(out, 'welcome_sign', [rbox('sign', (0, .01, 0), (.34, .03, .14), 'Honey wood', .4), rbox('letters', (0, -.006, 0), (.24, .01, .04), 'Walnut', .5)])


def frame_art(w, h):
    """A framed felt picture hanging from y = 0: a moonlit hill, a carrot, or Moku's portrait."""
    p = [rbox('frame', (0, .015, 0), (w, .03, h), 'Walnut', .3), rbox('canvas', (0, 0, 0), (w * .82, .01, h * .8), 'Indigo felt', .2)]
    p.append(ball('hill', (0, -.006, -h * .38), (w * .45, .01, h * .28), 'Sage felt', 14, 6))
    p.append(ball('moon', (w * .18, -.008, h * .18), (w * .08, .01, w * .08), 'Cream felt', 12, 6))
    return p


# ── Study.
def study_parts(out):
    p = [rbox('desk top', (0, 0, .5), (1.1, .52, .05), 'Honey wood', .3)]
    for x in (-.5, .5):
        for y in (-.2, .2): p.append(rbox('desk leg', (x, y, .24), (.05, .05, .48), 'Honey wood', .4))
    p.append(rbox('drawer', (.28, -.22, .43), (.4, .1, .1), 'Honey wood', .3)); p.append(ball('drawer knob', (.28, -.28, .43), (.02, .02, .02), 'Brass', 8, 6))
    save(out, 'desk', p)
    p = [cyl('stool seat', (0, 0, .32), .18, .05, 'Walnut', 24), ball('stool cushion', (0, 0, .36), (.17, .17, .045), 'Rust felt', 20, 8)]
    for i in range(3):
        a = i * 2 * math.pi / 3; p.append(rod('stool leg', (.13 * math.cos(a), .13 * math.sin(a), .3), (.17 * math.cos(a), .17 * math.sin(a), 0), .018, 'Walnut'))
    save(out, 'stool', p)
    p = [cyl('lamp base', (0, 0, .015), .07, .03, 'Iron', 16), rod('lamp arm', (0, 0, .02), (.05, 0, .3), .01, 'Iron'), rod('lamp arm 2', (.05, 0, .3), (-.08, 0, .38), .01, 'Iron'),
         cone('lamp shade', (-.1, 0, .34), .09, .04, .1, 'Mustard felt', 18, (0, -.5, 0)), ball('lamp bulb', (-.12, 0, .3), (.035, .035, .035), 'Lamp glow', 10, 6)]
    save(out, 'desk_lamp', p)
    p = []
    for i in range(3): p.append(rbox('stacked book', (rng.uniform(-.02, .02), 0, .02 + i * .04), (.22 - i * .02, .16, .038), BOOK_COLOURS[i * 3 % 10], .3)); p[-1].rotation_euler.z = rng.uniform(-.3, .3)
    save(out, 'book_stack', p)
    p = [rbox('notebook left', (-.08, 0, .008), (.15, .2, .012), 'Paper', .3), rbox('notebook right', (.08, 0, .008), (.15, .2, .012), 'Paper', .3), rbox('notebook cover', (0, 0, .002), (.33, .22, .006), 'Teal felt', .3)]
    for i in range(4): p.append(rbox('line', (.08, -.06 + i * .04, .015), (.1, .005, .002), 'Ink', .2))
    p.append(rod('pencil', (-.12, -.12, .012), (.06, -.13, .012), .006, 'Mustard felt'))
    save(out, 'notebook', p)
    p = [lathe('mug', [(0, 0), (.045, 0), (.05, .1), (.042, .1), (.042, .02), (0, .02)], 'Ceramic white', 18), curve('mug handle', [(.048, 0, .08), (.08, 0, .06), (.048, 0, .03)], .01, 'Ceramic white'), cyl('tea', (0, 0, .085), .042, .005, 'Walnut', 16)]
    save(out, 'mug', p)
    p = [rbox('shelf', (0, -.1, 0), (.9, .2, .035), 'Honey wood', .3)]
    for x in (-.35, .35): p.append(rbox('bracket', (x, -.05, -.07), (.03, .1, .12), 'Walnut', .4))
    save(out, 'wall_shelf', p)
    p = []
    x = -.13
    for i in range(6):
        w = rng.uniform(.035, .05); h = rng.uniform(.2, .26)
        p.append(rbox('book', (x + w / 2, -.08, h / 2), (w, .15, h), BOOK_COLOURS[(i * 3 + 1) % 10], .2)); x += w + .004
    p.append(rbox('leaning book', (x + .06, -.08, .1), (.04, .15, .22), BOOK_COLOURS[5], .2)); p[-1].rotation_euler.y = .45
    save(out, 'books_row', p)
    p = [lathe('pot', [(0, 0), (.07, 0), (.085, .12), (0, .12)], 'Terracotta', 18)]
    for i in range(6):
        a = i * 1.05; p.append(ball('leaf', (.07 * math.cos(a), .07 * math.sin(a), .19 + (i % 2) * .05), (.05, .025, .09), 'Leaf', 10, 6)); p[-1].rotation_euler = (0, .5 * math.cos(a), a)
    save(out, 'plant_small', p)
    p = [rbox('map paper', (0, 0, 0), (.62, .012, .42), 'Paper', .2)]
    for (x, z, w, h, m) in [(-.14, .06, .2, .14, 'Sage felt'), (.1, -.04, .22, .16, 'Sage felt'), (.2, .12, .08, .06, 'Mustard felt')]:
        p.append(ball('land', (x, -.008, z), (w / 2, .004, h / 2), m, 12, 6))
    p.append(rod('route', (-.2, -.01, -.1), (.18, -.01, .08), .004, 'Rust felt'))
    for x, z in ((-.28, .19), (.28, .19)): p.append(ball('pin', (x, -.012, z), (.015, .015, .015), 'Rust felt', 8, 6))
    save(out, 'map', p)
    p = [cyl('clock face', (0, 0, 0), .13, .03, 'Cream felt', 28, (math.pi / 2, 0, 0)), cyl('clock rim', (0, .005, 0), .145, .03, 'Walnut', 28, (math.pi / 2, 0, 0)),
         rod('hour hand', (0, -.02, 0), (.05, -.02, .04), .006, 'Ink'), rod('minute hand', (0, -.022, 0), (0, -.022, .1), .004, 'Ink')]
    save(out, 'clock', p)
    p = [rbox('rug', (0, 0, .005), (1.4, .9, .01), 'Indigo felt', .5)]
    for i, m in enumerate(['Cream felt', 'Mustard felt', 'Cream felt']): p.append(rbox('stripe', (0, -.3 + i * .3, .008), (1.3, .06, .01), m, .5))
    save(out, 'rug_rect', p)
    save(out, 'floor_cushion', [ball('cushion', (0, 0, .07), (.22, .22, .08), 'Mustard felt', 20, 10), ball('button', (0, 0, .15), (.02, .02, .01), 'Rust felt', 8, 6)])
    p = [cyl('globe base', (0, 0, .015), .08, .03, 'Walnut', 16), rod('globe stem', (0, 0, .02), (0, 0, .14), .01, 'Brass'),
         ball('globe', (0, 0, .25), (.11, .11, .11), 'Ceramic blue', 20, 12), ball('continent', (.05, -.06, .28), (.06, .04, .05), 'Sage felt', 10, 6)]
    p.append(curve('meridian', [(0, .0, .12), (-.13, 0, .25), (0, 0, .38)], .006, 'Brass'))
    save(out, 'globe', p)
    p = [rbox('cork board', (0, .01, 0), (.5, .02, .36), 'Cork', .2), rbox('board frame', (0, .02, 0), (.54, .02, .4), 'Walnut', .2)]
    for i, (x, z, m) in enumerate([(-.14, .08, 'Petal yellow'), (.06, .1, 'Rose felt'), (-.06, -.08, 'Paper'), (.16, -.06, 'Sage felt')]):
        p.append(rbox('note', (x, -.004, z), (.12, .008, .1), m, .1)); p[-1].rotation_euler.y = rng.uniform(-.2, .2)
    save(out, 'pinboard', p)
    p = [rod('cord', (0, 0, 0), (0, 0, -.35), .006, 'Ink'), lathe('pendant shade', [(0, -.35), (.02, -.35), (.15, -.5), (.16, -.52), (0, -.52)], 'Teal felt', 24), ball('pendant bulb', (0, 0, -.5), (.05, .05, .05), 'Lamp glow', 12, 8)]
    save(out, 'pendant_lamp', p)
    save(out, 'painting', frame_art(.5, .38))


# ── Kitchen.
def kitchen_parts(out):
    p = [lathe('stove body', [(0, .08), (.22, .08), (.25, .2), (.25, .52), (.2, .6), (0, .6)], 'Iron', 24)]
    for i in range(3):
        a = i * 2 * math.pi / 3 + .5; p.append(rod('stove leg', (.16 * math.cos(a), .16 * math.sin(a), .1), (.2 * math.cos(a), .2 * math.sin(a), 0), .02, 'Iron'))
    p.append(cyl('stove door glow', (0, -.24, .32), .08, .02, 'Window glow', 18, (math.pi / 2, 0, 0)))
    p.append(cyl('stove pipe', (0, .1, 1.1), .06, 1.0, 'Iron', 12))
    save(out, 'stove', p)
    p = [lathe('kettle', [(0, 0), (.08, 0), (.1, .06), (.08, .14), (.03, .16), (0, .17)], 'Rust felt', 20), curve('kettle spout', [(.08, 0, .06), (.14, 0, .12), (.16, 0, .14)], .012, 'Rust felt'),
         curve('kettle handle', [(-.06, 0, .14), (0, 0, .22), (.06, 0, .14)], .01, 'Iron')]
    save(out, 'kettle', p)
    p = [cyl('table top', (0, 0, .5), .38, .05, 'Honey wood', 32), rod('table leg', (0, 0, .48), (0, 0, .05), .04, 'Honey wood'), cyl('table foot', (0, 0, .03), .2, .05, 'Honey wood', 24)]
    p.append(cyl('tablecloth', (0, 0, .53), .3, .008, 'Cream felt', 32))
    save(out, 'table_round', p)
    p = [rbox('chair seat', (0, 0, .3), (.3, .3, .04), 'Walnut', .4), rbox('chair back', (0, .14, .5), (.3, .03, .36), 'Walnut', .4), ball('chair cushion', (0, 0, .33), (.13, .13, .03), 'Teal felt', 14, 6)]
    for x in (-.12, .12):
        for y in (-.12, .12): p.append(rbox('chair leg', (x, y, .14), (.035, .035, .28), 'Walnut', .4))
    save(out, 'chair', p)
    for i, (jam, h) in enumerate([('Jam red', .16), ('Jam amber', .13), ('Jam green', .18), ('Jam plum', .14), ('Carrot', .15)]):
        p = [cyl('jar glass', (0, -.08, h / 2), .05, h, 'Glass', 16), cyl('jam', (0, -.08, h * .4), .046, h * .78, jam, 16),
             cyl('lid', (0, -.08, h + .01), .052, .025, 'Rose felt' if i % 2 else 'Cream felt', 16)]
        save(out, 'jar_' + 'abcde'[i], p)
    p = [lathe('teapot', [(0, 0), (.07, 0), (.1, .06), (.08, .12), (.03, .13), (0, .14)], 'Ceramic blue', 20), curve('teapot spout', [(.09, 0, .05), (.15, 0, .1)], .012, 'Ceramic blue'),
         curve('teapot handle', [(-.09, 0, .1), (-.14, 0, .07), (-.09, 0, .03)], .01, 'Ceramic blue'), ball('teapot knob', (0, 0, .15), (.02, .02, .02), 'Ceramic white', 8, 6)]
    save(out, 'teapot', p)
    p = []
    for x in (-.07, .07):
        cup = lathe('cup', [(0, 0), (.035, 0), (.04, .06), (0, .06)], 'Ceramic white', 16); cup.location.x = x
        p += [cup, cyl('saucer', (x, 0, .004), .055, .008, 'Ceramic white', 16)]
    save(out, 'cups', p)
    p = [ball('loaf', (0, 0, .06), (.14, .08, .07), 'Bread', 18, 10)]
    for x in (-.06, 0, .06): p.append(rbox('score', (x, 0, .125), (.012, .1, .01), 'Walnut', .5)); p[-1].rotation_euler.z = .5
    save(out, 'bread', p)
    for i, m in enumerate(['Leaf', 'Sage felt', 'Leaf dark']):
        p = [rod('string', (0, 0, 0), (0, 0, -.12), .004, 'Paper')]
        for j in range(5): p.append(ball('herb', (rng.uniform(-.04, .04), 0, -.15 - j * .035), (.04, .03, .03), m, 10, 6))
        save(out, 'herbs_' + 'abc'[i], p)
    p = [rod('pan hook', (0, 0, 0), (0, 0, -.05), .005, 'Iron'), rod('pan handle', (0, -.01, -.05), (0, -.01, -.13), .012, 'Iron'), cyl('pan', (0, -.02, -.24), .11, .025, 'Iron', 20, (math.pi / 2, 0, 0))]
    save(out, 'pan', p)
    p = [rbox('rack', (0, -.05, 0), (.4, .1, .03), 'Honey wood', .3)]
    for i in range(4): p.append(cyl('plate', (-.15 + i * .1, -.05, .1), .09, .012, 'Ceramic white' if i % 2 else 'Ceramic blue', 20, (math.pi / 2 - .2, 0, 0)))
    save(out, 'plate_rack', p)
    p = [lathe('bowl', [(0, 0), (.08, 0), (.14, .08), (0, .08)], 'Ceramic white', 20)]
    for i in range(5):
        a = i * 1.26; p.append(ball('carrot', (.06 * math.cos(a), .06 * math.sin(a), .09), (.025, .025, .07), 'Carrot', 10, 6)); p[-1].rotation_euler = (1.2, 0, a)
        p.append(ball('carrot top', (.1 * math.cos(a), .1 * math.sin(a), .1), (.02, .02, .04), 'Leaf', 8, 5))
    save(out, 'bowl_carrots', p)
    p = [lathe('vase', [(0, 0), (.05, 0), (.07, .08), (.04, .16), (.05, .18), (0, .18)], 'Ceramic blue', 18)]
    for i, m in enumerate(['Petal pink', 'Petal yellow', 'Petal white', 'Petal red']):
        a = i * 1.6; t = (.07 * math.cos(a), .07 * math.sin(a), .32 + .03 * (i % 2))
        p.append(rod('stem', (0, 0, .16), t, .006, 'Leaf')); p.append(ball('bloom', t, (.04, .04, .03), m, 10, 6))
    save(out, 'vase_flowers', p)


# ── Bedroom.
def bedroom_parts(out):
    p = [rbox('bed base', (0, 0, .16), (1.3, .7, .2), 'Honey wood', .3), rbox('headboard', (-.62, 0, .45), (.08, .74, .7), 'Honey wood', .3)]
    p.append(ball('headboard top', (-.62, 0, .8), (.05, .37, .1), 'Honey wood', 16, 8))
    p.append(rbox('footboard', (.62, 0, .3), (.06, .72, .36), 'Honey wood', .3))
    p.append(rbox('mattress', (0, 0, .3), (1.2, .64, .1), 'Cream felt', .6))
    save(out, 'bed', p)
    save(out, 'quilt', [rbox('quilt', (.1, 0, .37), (1.0, .7, .05), 'Cream felt', .8)])
    for i, m in enumerate(['Rust felt', 'Mustard felt', 'Teal felt', 'Rose felt', 'Indigo felt', 'Sage felt', 'Plum felt']):
        save(out, 'patch_' + str(i), [rbox('patch', (0, 0, 0), (.13, .13, .012), m, .5)])
    save(out, 'pillow', [ball('pillow', (0, 0, .06), (.12, .22, .06), 'Petal white', 18, 10)])
    p = [rbox('nightstand', (0, 0, .2), (.32, .3, .4), 'Walnut', .3), rbox('nightstand drawer', (0, -.155, .26), (.24, .01, .1), 'Honey wood', .3), ball('nightstand knob', (0, -.17, .26), (.015, .015, .015), 'Brass', 8, 6)]
    save(out, 'nightstand', p)
    p = [lathe('bedside base', [(0, 0), (.05, 0), (.06, .06), (.02, .14), (0, .14)], 'Ceramic white', 16), cone('bedside shade', (0, 0, .2), .09, .05, .1, 'Rose felt', 18), ball('bedside bulb', (0, 0, .17), (.035, .035, .035), 'Lamp glow', 10, 6)]
    save(out, 'bed_lamp', p)
    p = [rbox('dresser', (0, 0, .3), (.7, .34, .6), 'Honey wood', .2)]
    for z in (.15, .33, .5):
        p.append(rbox('dresser drawer', (0, -.172, z), (.62, .01, .14), 'Plank', .3))
        for x in (-.15, .15): p.append(ball('dresser knob', (x, -.185, z), (.018, .018, .018), 'Brass', 8, 6))
    save(out, 'dresser', p)
    save(out, 'mirror', [ball('mirror frame', (0, .01, 0), (.2, .02, .26), 'Brass', 20, 10), ball('mirror glass', (0, 0, 0), (.17, .02, .23), 'Glass', 20, 10)])
    p = [rod('star string', (0, 0, 0), (0, 0, -.18), .003, 'Paper')]
    me = bpy.data.meshes.new('paper star'); bm = bmesh.new()
    pts = [(math.cos(math.pi / 2 + k * math.pi / 5) * (.07 if k % 2 == 0 else .03), math.sin(math.pi / 2 + k * math.pi / 5) * (.07 if k % 2 == 0 else .03)) for k in range(10)]
    front = [bm.verts.new((x, -.006, z - .25)) for x, z in pts]; back = [bm.verts.new((x, .006, z - .25)) for x, z in pts]
    bm.faces.new(front[::-1]); bm.faces.new(back)
    for k in range(10): bm.faces.new((front[k], front[(k + 1) % 10], back[(k + 1) % 10], back[k]))
    bm.to_mesh(me); bm.free(); star = bpy.data.objects.new('paper star', me); bpy.context.collection.objects.link(star); finish(star, 'paper star', M['Star glow'])
    p.append(star); save(out, 'paper_star', p)
    p = [ball('plush body', (0, 0, .07), (.07, .06, .08), 'Rose felt', 14, 8), ball('plush head', (0, 0, .17), (.06, .06, .055), 'Rose felt', 14, 8)]
    for x in (-.025, .025): p.append(ball('plush ear', (x, 0, .25), (.015, .012, .05), 'Rose felt', 8, 6))
    save(out, 'plush_bunny', p)
    p = [ball('carrot plush', (0, 0, .05), (.04, .04, .12), 'Carrot', 12, 8), ball('carrot plush top', (0, 0, .18), (.04, .03, .04), 'Leaf', 8, 6)]
    p[0].rotation_euler.y = 1.3; p[1].location = (.15, 0, .06)
    save(out, 'plush_carrot', p)
    p = []
    for x in (-.06, .06): p.append(ball('slipper', (x, 0, .03), (.05, .1, .035), 'Rose felt', 14, 8)); p.append(ball('pompom', (x, -.07, .06), (.025, .025, .025), 'Petal white', 8, 6))
    save(out, 'slippers', p)
    save(out, 'frame_tiny', frame_art(.18, .22))
    p = [rbox('book', (0, 0, .02), (.16, .12, .03), 'Teal felt', .3), rbox('book 2', (.01, 0, .05), (.14, .11, .028), 'Rust felt', .3)]
    save(out, 'bedside_books', p)


# ── Library.
def library_parts(out):
    for i, m in enumerate(BOOK_COLOURS):
        w = .035 + .012 * (i % 3); h = .2 + .025 * ((i * 7) % 4)
        p = [rbox('book', (0, -.07, h / 2), (w, .14, h), m, .2), rbox('book band', (0, -.141, h * .75), (w * 1.02, .004, .02), 'Brass' if i % 2 else 'Cream felt', .2)]
        save(out, 'book_' + str(i), p)
    p = [rbox('armchair seat', (0, 0, .25), (.62, .56, .2), 'Plum felt', .6), rbox('armchair back', (0, .24, .55), (.62, .14, .55), 'Plum felt', .6)]
    for x in (-.3, .3): p.append(rbox('armchair arm', (x, 0, .38), (.12, .56, .22), 'Plum felt', .7))
    for x in (-.24, .24):
        for y in (-.2, .2): p.append(cone('armchair foot', (x, y, .06), .03, .02, .12, 'Walnut', 8))
    p.append(ball('armchair cushion', (0, -.02, .38), (.24, .22, .05), 'Mustard felt', 16, 8))
    save(out, 'armchair', p)
    p = [cyl('floor lamp base', (0, 0, .02), .12, .04, 'Brass', 18), rod('floor lamp pole', (0, 0, .03), (0, 0, 1.25), .015, 'Brass'),
         lathe('floor lamp shade', [(.16, 1.12), (.1, 1.34), (0, 1.34)], 'Cream felt', 22), ball('floor lamp bulb', (0, 0, 1.18), (.05, .05, .05), 'Lamp glow', 10, 6)]
    save(out, 'floor_lamp', p)
    p = [cyl('side table top', (0, 0, .4), .18, .03, 'Walnut', 20), rod('side table leg', (0, 0, .39), (0, 0, .02), .025, 'Walnut'), cyl('side table foot', (0, 0, .015), .12, .03, 'Walnut', 16),
         cyl('candle', (0, 0, .47), .025, .12, 'Cream felt', 12), ball('flame', (0, 0, .56), (.015, .015, .03), 'Lamp glow', 8, 6)]
    save(out, 'side_table', p)
    p = [rod('ladder rail', (-.18, 0, 0), (-.18, .3, 2.0), .02, 'Honey wood'), rod('ladder rail', (.18, 0, 0), (.18, .3, 2.0), .02, 'Honey wood')]
    for i in range(1, 9): z = i * .22; p.append(rod('rung', (-.18, z * .15, z), (.18, z * .15, z), .015, 'Honey wood'))
    save(out, 'ladder', p)


# ── Garden.
def garden_parts(out):
    p = [ball('carrot shoulder', (0, 0, .015), (.04, .04, .025), 'Carrot', 12, 6)]
    for i in range(3):
        a = i * 2.1; p.append(ball('carrot leaf', (.02 * math.cos(a), .02 * math.sin(a), .1), (.018, .01, .08), 'Leaf', 8, 5)); p[-1].rotation_euler = (.35 * math.sin(a), .35 * math.cos(a), a)
    save(out, 'carrot', p)
    p = [ball('cabbage', (0, 0, .08), (.12, .12, .09), 'Cabbage', 16, 10)]
    for i in range(5):
        a = i * 1.26; p.append(ball('cabbage leaf', (.1 * math.cos(a), .1 * math.sin(a), .06), (.08, .05, .06), 'Leaf', 10, 6)); p[-1].rotation_euler.z = a
    save(out, 'cabbage', p)
    p = []
    for i in range(7):
        a = i * .9; p.append(ball('lettuce leaf', (.04 * math.cos(a), .04 * math.sin(a), .05), (.07, .04, .05), 'Grass light' if i % 2 else 'Cabbage', 10, 6)); p[-1].rotation_euler = (0, .6, a)
    save(out, 'lettuce', p)
    for key, m in [('a', 'Petal white'), ('b', 'Petal yellow'), ('c', 'Petal pink'), ('d', 'Petal blue'), ('e', 'Petal red')]:
        h = .14 + .04 * ('abcde'.index(key) % 3)
        p = [rod('stem', (0, 0, 0), (0, 0, h), .008, 'Leaf'), ball('leaf', (.03, 0, h * .4), (.03, .012, .015), 'Leaf', 8, 5)]
        for j in range(5):
            a = j * 2 * math.pi / 5; p.append(ball('petal', (.03 * math.cos(a), .03 * math.sin(a), h), (.028, .025, .012), m, 8, 5))
        p.append(ball('flower heart', (0, 0, h + .01), (.018, .018, .014), 'Petal yellow' if key != 'b' else 'Walnut', 8, 5))
        save(out, 'flower_' + key, p)
    p = [rod('sunflower stem', (0, 0, 0), (0, 0, .55), .014, 'Leaf'), ball('sunflower leaf', (.06, 0, .25), (.07, .015, .035), 'Leaf', 10, 6)]
    for j in range(12):
        a = j * 2 * math.pi / 12; p.append(ball('petal', (.08 * math.cos(a), -.02, .58 + .08 * math.sin(a)), (.04, .01, .02), 'Petal yellow', 8, 5)); p[-1].rotation_euler.y = -a
    p.append(cyl('sunflower heart', (0, -.03, .58), .055, .03, 'Walnut', 18, (math.pi / 2, 0, 0)))
    save(out, 'sunflower', p)
    p = []
    for j in range(8):
        a = j * 2 * math.pi / 8; p.append(ball('pumpkin lobe', (.06 * math.cos(a), .06 * math.sin(a), .09), (.08, .08, .09), 'Pumpkin', 12, 8)); p[-1].rotation_euler.z = a
    p.append(rod('pumpkin stalk', (0, 0, .16), (.02, 0, .22), .015, 'Leaf dark'))
    save(out, 'pumpkin', p)
    p = [ball('bush', (0, 0, .16), (.22, .2, .18), 'Leaf dark', 16, 10), ball('bush top', (.06, -.04, .26), (.14, .13, .12), 'Leaf', 14, 8)]
    for j in range(5): p.append(ball('berry', (rng.uniform(-.15, .15), -.18, rng.uniform(.1, .3)), (.02, .02, .02), 'Petal red', 8, 5))
    save(out, 'bush', p)
    save(out, 'fence_post', [rbox('post', (0, 0, .2), (.06, .06, .4), 'Plank', .4), cone('post cap', (0, 0, .42), .045, .0, .06, 'Plank', 4, (0, 0, math.pi / 4)), rbox('rail', (.13, 0, .28), (.26, .03, .05), 'Plank', .4)])
    save(out, 'stepping_stone', [ball('stone', (0, 0, .02), (.13, .1, .03), 'Stone', 14, 6)])
    p = [rod('scarecrow pole', (0, 0, 0), (0, 0, .95), .02, 'Walnut'), rod('scarecrow arms', (-.28, 0, .7), (.28, 0, .7), .018, 'Walnut'),
         rbox('scarecrow shirt', (0, 0, .62), (.26, .1, .26), 'Rust felt', .6), ball('scarecrow head', (0, 0, .88), (.09, .09, .09), 'Bread', 12, 8), cone('scarecrow hat', (0, 0, 1.0), .14, .05, .12, 'Mustard felt', 16)]
    save(out, 'scarecrow', p)
    p = [lathe('can', [(0, 0), (.08, 0), (.085, .14), (0, .14)], 'Teal felt', 18), rod('can spout', (.07, 0, .05), (.18, 0, .15), .012, 'Teal felt'), curve('can handle', [(-.06, 0, .14), (0, 0, .2), (.06, 0, .14)], .01, 'Teal felt')]
    save(out, 'watering_can', p)
    p = [rod('birdhouse pole', (0, 0, 0), (0, 0, .7), .02, 'Walnut'), rbox('birdhouse', (0, 0, .8), (.16, .16, .18), 'Mustard felt', .3), cyl('hole', (0, -.08, .82), .03, .01, 'Walnut', 12, (math.pi / 2, 0, 0))]
    for s in (-1, 1): p.append(rbox('birdhouse roof', (s * .06, 0, .93), (.14, .2, .02), 'Rust felt', .4)); p[-1].rotation_euler.y = s * .7
    save(out, 'birdhouse', p)
    save(out, 'soil_bed', [rbox('bed soil', (0, 0, .03), (1.0, .36, .06), 'Soil', .6), rbox('bed frame', (0, 0, .025), (1.06, .42, .05), 'Plank dark', .4)])


# ── The observatory, lanterns and stars.
def sky_parts(out):
    p = [cyl('telescope tube', (0, 0, .62), .07, .6, 'Brass', 18, (.9, 0, 0)), cyl('telescope eyepiece', (0, .24, .4), .03, .1, 'Iron', 12, (.9, 0, 0))]
    for x, y in ((-.14, -.1), (.14, -.1), (0, .16)): p.append(rod('tripod', (x, y, 0), (0, 0, .5), .015, 'Walnut'))
    save(out, 'telescope', p)
    save(out, 'bulb', [ball('bulb', (0, 0, -.05), (.035, .035, .045), 'Lamp glow', 10, 6), cyl('bulb cap', (0, 0, -.01), .016, .02, 'Brass', 8)])
    save(out, 'star', [ball('star', (0, 0, 0), (.03, .03, .03), 'Star glow', 8, 5)])


def build_all(out):
    for build in (door_parts, entry_parts, study_parts, kitchen_parts, bedroom_parts, library_parts, garden_parts, sky_parts): build(out)
    return PARTS
