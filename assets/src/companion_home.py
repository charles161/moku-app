"""What every companion's home shares with today's cottage (house_kit.py): the felt lawn, the layout, the slots.

A companion's home is drawn by the same renderer as Moku's cottage (HomeLayout in HomeWorld.swift), so it keeps the
cottage's contract exactly: 24 pieces in 5 stages of 4, 4, 6, 4 and 6, one piece per 10 focused minutes, the house done
at 4 hours, a site that changes with the stages (terrain), five camera framings and a warm light when it's finished.
Its files go in world/<companion>/: layout.json (the home under homes["<companion>"], every slot's home is
"<companion>"), manifest.json and one USDZ per part.

Unlike the cottage, each piece is saved around its own anchor (its footprint's centre, on the ground or wherever it
rests) and its slot carries that anchor as a translation. The renderer drops a new piece in and squashes it about its
own origin, so a nose cone or a turret lands on its own base instead of squashing towards the middle of the plot.

The names the app shows for the pieces and stages ("the nose cone", "The hull") travel in the layout too, under
homes["<companion>"].names, so the popover, the menu bar and Your day can say them."""
import math, json
from pathlib import Path
import bpy, bmesh
from mathutils import Vector, Matrix
from common import ROOT, export, select, triangles, finish
import home_parts as H
from home_parts import ball, cone, cyl

THRESHOLDS = [0, 40, 80, 140, 180, 240]
ROOMS = ['ground', 'frame', 'walls', 'roof', 'home', 'complete']
STAGE_SIZES = [4, 4, 6, 4, 6]   # the cottage's: ground, frame, walls, roof, home
# The cottage's camera direction: from the front left, a little above (house_kit.py).
VIEW = Vector((-.34, -1.0, .42)).normalized()

# Colours the cottage's palette doesn't have. Most aren't in runtime/materials.json, so the app draws them with the
# colour and roughness stored in the USDZ itself (no felt normal map): fine for painted metal and cardboard. Sage
# ceramic and Water surface are (the home's teapot and pond), so the app's own values win for those two.
EXTRA_PALETTE = {
    'Slate': ('5E676C', .62, False, False), 'Slate light': ('7D878C', .6, False, False), 'Steel': ('A7AFB2', .45, False, False),
    'Cardboard': ('C49C6C', .92, False, False), 'Cardboard light': ('D4B184', .92, False, False), 'Cardboard dark': ('8F6A44', .95, False, False),
    'Kraft tape': ('DCC08E', .55, False, False), 'Sisal': ('D8BE8A', .97, False, False),
    'Sage ceramic': ('87A187', .4, False, False), 'Water surface': ('8AB0A8', .13, False, False),
}

C = Matrix.Rotation(-math.pi / 2, 4, 'X')   # Blender (z up, front -y) to RealityKit (y up, front +z)


def setup():
    H.PALETTE.update(EXTRA_PALETTE)
    H.materials(ROOT)


def point(v):
    return [round(v[0], 4), round(v[2], 4), round(-v[1], 4)]


def slot(asset, home, anchor=(0, 0, 0)):
    t, q, s = (C @ Matrix.Translation(Vector(anchor)) @ C.inverted()).decompose()
    return {'asset': asset, 't': [round(v, 4) + 0.0 for v in t], 'q': [round(q.x, 5), round(q.y, 5), round(q.z, 5), round(q.w, 5)],
            's': [round(v, 4) for v in s], 'home': home}


def save(out, name, objs, anchor=(0, 0, 0), limit=12000):
    """Joins `objs` into one part around `anchor`, triangulated, and exports it to out/name.usdz."""
    o = H.join(name, objs); o.data.name = name   # the mesh's name, not Blender's running count, so exports stay stable
    o.data.transform(Matrix.Translation(-Vector(anchor)))
    t = o.modifiers.new('triangulate', 'TRIANGULATE'); t.quad_method = 'BEAUTY'; t.ngon_method = 'BEAUTY'; t.keep_custom_normals = True
    select([o]); bpy.context.view_layer.objects.active = o; bpy.ops.object.modifier_apply(modifier=t.name)
    export(out / (name + '.usdz'), [o]); count = triangles([o]); assert count < limit, (name, count)
    H.MANIFEST.append({'name': name, 'triangles': count})
    bpy.data.objects.remove(o, do_unlink=True)
    return name


def save_piece(out, name, objs, anchor=None):
    """A piece: saved around `anchor`, or, for a piece spread over the home (windows on three towers), around the
    middle of its footprint at its lowest point, so it lands as one. Returns (name, anchor)."""
    if anchor is None:
        o = H.join(name, objs); vs = [v.co for v in o.data.vertices]
        anchor = ((min(v.x for v in vs) + max(v.x for v in vs)) / 2, (min(v.y for v in vs) + max(v.y for v in vs)) / 2, min(v.z for v in vs))
        objs = [o]
    return save(out, name, objs, anchor), tuple(round(a, 4) for a in anchor)


# ── Shapes both homes use.
def M(x, y, z=0, rz=0):
    return Matrix.Translation((x, y, z)) @ Matrix.Rotation(math.radians(rz), 4, 'Z')


def placed(name, objs, matrix):
    """Joins parts built around the origin and sets them in place with `matrix`."""
    o = H.join(name, objs); o.matrix_world = matrix @ o.matrix_world; return [o]


def prism(name, outline, thickness, material, bevel=.012):
    """A flat shape from (x, z) points, `thickness` deep along y, with softened edges."""
    me = bpy.data.meshes.new(name); bm = bmesh.new()
    front = [bm.verts.new((x, -thickness / 2, z)) for x, z in outline]; back = [bm.verts.new((x, thickness / 2, z)) for x, z in outline]
    bm.faces.new(front); bm.faces.new(back[::-1])
    n = len(outline)
    for i in range(n): bm.faces.new((front[(i + 1) % n], front[i], back[i], back[(i + 1) % n]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(o); finish(o, name, H.M[material])
    if bevel:
        b = o.modifiers.new('soft', 'BEVEL'); b.width = bevel; b.segments = 2; b.limit_method = 'ANGLE'
        bpy.context.view_layer.objects.active = o; bpy.ops.object.modifier_apply(modifier=b.name)
    return o


def circle(name, c, r, axis_a, axis_b, thick, material, n=24):
    """A ring of tube round `c`, in the plane of axis_a and axis_b."""
    pts = [tuple(Vector(c) + axis_a * (r * math.cos(2 * math.pi * k / n)) + axis_b * (r * math.sin(2 * math.pi * k / n))) for k in range(n + 1)]
    return H.curve(name, pts, thick, material, 2)


def cloth(name, top_left, width, height, material, wave=.035, n=10):
    """A flag hanging from `top_left`, out along +x, with a soft wave."""
    x, y, z = top_left
    me = bpy.data.meshes.new(name); bm = bmesh.new(); top, bot = [], []
    for k in range(n + 1):
        u = k / n; w = wave * math.sin(u * math.pi * 1.6)
        top.append(bm.verts.new((x + u * width, y + w, z))); bot.append(bm.verts.new((x + u * width, y + w, z - height)))
    for k in range(n): bm.faces.new((bot[k], bot[k + 1], top[k + 1], top[k]))
    bm.to_mesh(me); bm.free(); o = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(o); finish(o, name, H.M[material])
    s = o.modifiers.new('cloth', 'SOLIDIFY'); s.thickness = .02; bpy.context.view_layer.objects.active = o; bpy.ops.object.modifier_apply(modifier=s.name)
    return o


# ── The lawn: the cottage's round felt island over a bank of earth (house_kit.py plot), dressed by each home.
RADIUS = 3.3
LAWN = (RADIUS + .06, RADIUS * .85 + .06, .12)   # the lawn's half sizes; its centre is at z = -.03


def lawn_z(x, y):
    """The lawn's top at (x, y): where anything standing on the grass rests."""
    k = 1 - (x / LAWN[0]) ** 2 - (y / LAWN[1]) ** 2
    return -.03 + LAWN[2] * math.sqrt(max(0.0, k))


def lawn(rng, keep_clear, dress, count=80):
    """The island, and `count` bits of dressing scattered where `keep_clear(x, y)` is false: dress(i, x, y) → parts."""
    p = [ball('bank', (0, 0, -.64), (RADIUS, RADIUS * .85, .6), 'Earth side', 56, 20)]
    p.append(ball('lawn', (0, 0, -.03), LAWN, 'Grass felt', 56, 14))
    for i in range(28):
        a = i * 2 * math.pi / 28; p.append(ball('scallop', ((RADIUS - .04) * math.cos(a), (RADIUS * .85 - .04) * math.sin(a), -.05), (.26, .26, .1), 'Grass felt', 10, 6))
    for i in range(12):
        a = i * 2 * math.pi / 12 + .3; p.append(ball('bank stone', (RADIUS * .96 * math.cos(a), RADIUS * .82 * math.sin(a), -.32 - .15 * (i % 3)), (.18, .15, .13), 'Stone', 10, 6))
    for i in range(count):
        a = rng.uniform(0, 2 * math.pi); rr = RADIUS * math.sqrt(rng.uniform(.1, .93)); x, y = rr * math.cos(a), rr * .85 * math.sin(a)
        if keep_clear(x, y): continue
        p += dress(i, x, y)
    return p


def tuft(x, y, material='Grass deep'):
    return [cone('tuft', (x, y, lawn_z(x, y) + .04), .04, 0, .1, material, 5)]


def young_tree(x, y, s=1.0):
    """The cottage's young tree (house_kit.py), standing on the lawn."""
    z = lawn_z(x, y) - .02
    p = [H.rod('trunk', (x, y, z), (x + .03, y, z + 1.0 * s), .06 * s, 'Bark')]
    for (dx, dy, dz, r, m) in [(-.2, 0, 1.05, .33, 'Leaf'), (.22, .04, 1.1, .34, 'Leaf dark'), (0, -.1, 1.35, .36, 'Grass light'), (.05, .15, 1.25, .3, 'Leaf')]:
        p.append(ball('crown', (x + dx * s, y + dy * s, z + dz * s), (r * s, r * .9 * s, r * .92 * s), m, 16, 10))
    return p


def cameras(framings):
    """[(threshold, target, distance)] → the layout's cameras, along the cottage's view direction."""
    return [{'threshold': th, 'target': point(Vector(t)), 'from': point(Vector(t) + VIEW * d)} for th, t, d in framings]


def write(out, key, plot, site, pieces, names, light, framings, actor, actor_scale=.6):
    """layout.json and manifest.json for a home: `pieces` are 24 (name, anchor) in build order, `site` six terrain parts."""
    assert len(pieces) == sum(STAGE_SIZES) == len(names['pieces']), (len(pieces), len(names['pieces']))
    assert len(site) == 6 and len(names['stages']) == 5
    items = [slot(n, key, a) for n, a in pieces]
    stages, first = [], 0
    for i, size in enumerate(STAGE_SIZES):
        stages.append({'threshold': THRESHOLDS[i], 'room': ROOMS[i], 'structure': [], 'items': items[first:first + size]}); first += size
    stages.append({'threshold': THRESHOLDS[-1], 'room': ROOMS[-1], 'structure': [], 'items': [], 'light': point(light)})
    starts = [sum(STAGE_SIZES[:i]) for i in range(5)]
    home = {'base': [slot(plot, key)], 'terrain': [slot(n, key) for n in site], 'stages': stages,
            'moku': {k: point(v[:3]) + [v[3]] for k, v in actor.items()}, 'bulbs': [], 'stars': [], 'mokuScale': actor_scale,
            'cameras': cameras(framings),
            'names': {'home': names['home'], 'stages': [{'name': s, 'first': f} for s, f in zip(names['stages'], starts)],
                      'pieces': names['pieces'], 'finished': names['finished']}}
    layout = {'schemaVersion': 1, 'thresholds': THRESHOLDS, 'rooms': ROOMS, 'pointsPerItem': 10,
              'note': f"{names['home']}: points are focused minutes today; one piece per 10 minutes; done at 4 hours.",
              'homes': {key: home}}
    (out / 'layout.json').write_text(json.dumps(layout) + '\n')
    (out / 'manifest.json').write_text(json.dumps({'parts': H.MANIFEST}, indent=1) + '\n')
    print('COMPANION_HOME', key, len(H.MANIFEST), 'parts', sum(p['triangles'] for p in H.MANIFEST), 'triangles')
