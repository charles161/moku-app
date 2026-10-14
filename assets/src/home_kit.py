"""Moku's home (docs/specs/home.md): the burrow and the treehouse, room by room.

Builds the parts (home_parts.py) and both homes' shells, places every item in the order it appears (one per 10
focused minutes), and writes world/home/layout.json for the app plus Blender previews of both homes at a few ages.

Run: Blender --background --factory-startup --python-exit-code 1 --python assets/src/home_kit.py [-- --previews]"""
import sys, math, json, random
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ROOT, reset, select, export, triangles, finish
import home_parts as H
from home_parts import rbox, ball, cyl, cone, rod, curve, lathe, join
import bpy, bmesh
from mathutils import Vector, Matrix, Quaternion, Euler

OUT = ROOT / 'world/home'; KIT = OUT / 'kit'; PRE = ROOT / 'previews/home'
for d in (OUT, KIT, OUT / 'burrow', OUT / 'treehouse', PRE): d.mkdir(parents=True, exist_ok=True)
reset(); H.materials(ROOT); rng = random.Random(5)

# The milestones (focused minutes, one point each) and the rooms they open. Stage 7's items are stars, forever.
THRESHOLDS = [0, 30, 120, 300, 600, 1500, 4000, 10000]
ROOMS = ['door', 'entry', 'study', 'kitchen', 'bedroom', 'library', 'garden', 'observatory']
SIZES = {'entry': (1.5, 1.2, 1.6), 'study': (2.6, 1.3, 1.7), 'kitchen': (2.2, 1.3, 1.7), 'bedroom': (2.8, 1.3, 1.6), 'library': (3.0, 1.2, 2.3)}
WALLS = {'entry': 'Wall sage', 'study': 'Wall cream', 'kitchen': 'Wall butter', 'bedroom': 'Wall rose', 'library': 'Wall teal'}
ROOFS = {'entry': 'Roof terracotta', 'study': 'Roof teal', 'kitchen': 'Roof terracotta', 'bedroom': 'Roof teal', 'library': 'Roof terracotta'}
BACK = .07  # the back wall's face is this far in front of the room's depth


def place(asset, x, y, z, rz=0, s=1, ry=0, rx=0):
    """An item in room-local space (front centre of the floor at the origin, depth +y, the back wall at y = D)."""
    return {'asset': asset, 'm': Matrix.Translation((x, y, z)) @ Euler((math.radians(rx), math.radians(ry), math.radians(rz))).to_matrix().to_4x4() @ Matrix.Diagonal((s, s, s, 1))}


# ── Room interiors, shared by both homes, in the order they appear.
def entry_items():
    W, D, Hh = SIZES['entry']
    return [place('rug_round', 0, .6, 0, s=.9), place('coat_hooks', -.35, D, 1.05), place('bench', .28, D - .16, 0), place('boots', .55, .45, 0, 15),
            place('umbrella_stand', -.55, .95, 0), place('sconce', .25, D, 1.28), place('fern', -.52, .38, 0), place('picture_small', .3, D, .82), place('welcome_sign', -.35, D, 1.36)]


def study_items():
    W, D, Hh = SIZES['study']; top = .525
    return [place('desk', .1, .45, 0), place('stool', .1, 1.0, 0), place('desk_lamp', -.32, .52, top, 25), place('book_stack', .46, .5, top),
            place('notebook', .08, .36, top, -8), place('mug', .3, .3, top), place('wall_shelf', -.75, D, 1.2), place('books_row', -.82, D, 1.218),
            place('plant_small', 1.05, .92, 0, s=1.4), place('map', .4, D, 1.12), place('clock', -.2, D, 1.42), place('rug_rect', .1, .62, 0, s=.95),
            place('floor_cushion', -.85, .5, 0), place('globe', .95, .38, 0), place('pinboard', 1.0, D, .95), place('plant_small', -.45, D - .1, 1.218, s=.8),
            place('pendant_lamp', .1, .7, Hh), place('painting', -.75, D, .72)]


def kitchen_items():
    W, D, Hh = SIZES['kitchen']; table = .535; shelf = 1.268
    items = [place('stove', -.72, .9, 0), place('kettle', -.72, .9, .6), place('table_round', .3, .6, 0), place('chair', .3, 1.05, 0), place('chair', .85, .55, 0, -90),
             place('wall_shelf', .35, D, 1.25)]
    items += [place('jar_' + k, -.02 + i * .15, D, shelf) for i, k in enumerate('abcde')]
    items += [place('teapot', .3, .55, table), place('cups', .46, .42, table), place('bread', .12, .45, table),
              place('herbs_a', -.22, 1.0, Hh), place('herbs_b', -.06, 1.05, Hh), place('herbs_c', .1, 1.0, Hh), place('pan', -.3, D - .03, 1.42),
              place('plate_rack', .9, D, .95), place('bowl_carrots', -.2, .38, 0), place('vase_flowers', .78, D - .1, shelf), place('rug_round', .3, .6, 0, s=1.1),
              place('pendant_lamp', .3, .6, Hh), place('painting', -.12, D, .9, s=.8), place('sconce', 1.0, D, 1.4), place('mug', .18, .72, table, 40),
              place('plant_small', .98, .98, 0, s=1.3), place('picture_small', -.32, D, .62), place('frame_tiny', .1, D, .62), place('floor_cushion', -.2, .95, 0, s=.8)]
    return items


def bedroom_items():
    W, D, Hh = SIZES['bedroom']; mattress = .35
    items = [place('bed', .5, .75, 0), place('quilt', .5, .75, 0), place('pillow', -.02, .75, mattress), place('nightstand', -.35, 1.02, 0), place('bed_lamp', -.42, 1.02, .4),
             place('rug_round', .3, .45, 0, s=.9), place('dresser', -1.0, 1.1, 0), place('mirror', -1.0, D, 1.08), place('slippers', .15, .25, 0, 10),
             place('plush_bunny', 1.0, .55, .4, 20), place('plush_carrot', -.62, .42, 0, 30), place('bedside_books', -.26, .98, .4, 10),
             place('frame_tiny', .2, D, 1.12), place('frame_tiny', .48, D, 1.22), place('frame_tiny', .76, D, 1.1), place('picture_small', 1.12, D, 1.2), place('sconce', -.3, D, 1.32)]
    for r in range(5):  # the quilt, sewn one patch at a time
        for c in range(7): items.append(place('patch_' + str((r * 3 + c) % 7), .6 - .405 + c * .135, .75 - .27 + r * .135, .401))
    for i in range(38):  # paper stars hung from the ceiling
        a = i * 2.399; x = -1.25 + (i * .9131 % 2.5); y = .25 + ((i * .618) % 1.0) * .85
        items.append(place('paper_star', x, y, Hh, rz=math.degrees(a) % 360, s=.8 + .3 * ((i * .37) % 1)))
    assert len(items) == 90, len(items)
    return items


def library_items():
    W, D, Hh = SIZES['library']
    items = [place('armchair', -.95, .55, 0, 20), place('floor_lamp', -1.32, .4, 0), place('side_table', -.42, .38, 0), place('rug_rect', .15, .55, 0, s=1.2),
             place('ladder', .85, .95, 0), place('globe', 1.25, .38, 0), place('plant_small', 1.3, .95, 0, s=1.5)]
    rows = [.37, .77, 1.17, 1.57, 1.97]; order = [2, 1, 3, 0, 4]  # eye level first, then outwards
    widths = [.035 + .012 * (i % 3) for i in range(10)]
    k = 0
    for row in order:
        x = -1.36
        while x < 1.34 and len(items) < 250:
            i = (k * 7 + row * 3) % 10; w = widths[i]; lean = 0
            if k % 17 == 16: lean = 18  # now and then a book leans on its neighbour
            items.append(place('book_' + str(i), x + w / 2 + (.02 if lean else 0), D, rows[row] + .018, ry=lean)); x += w + (.03 if lean else .004); k += 1
    assert len(items) == 250, len(items)
    return items


def library_shelves(room_m):
    """The library's shelves come with the room: five boards across the back wall and uprights between them."""
    W, D, Hh = SIZES['library']; p = []
    for z in [.35, .75, 1.15, 1.55, 1.95]: p.append(rbox('shelf board', (0, D - BACK - .13, z), (W - .2, .26, .035), 'Walnut', .3))
    for x in [-1.42, -.7, 0, .7, 1.42]: p.append(rbox('shelf upright', (x, D - BACK - .13, 1.15), (.04, .26, 1.7), 'Walnut', .3))
    for o in p: o.matrix_world = room_m @ o.matrix_world
    return p


# ── Slot output: RealityKit space (y up, front +z). Blender (x, y, z) is RealityKit (x, z, −y).
C = Matrix.Rotation(-math.pi / 2, 4, 'X')
def slot(asset, m, **extra):
    r = C @ m @ C.inverted(); t, q, s = r.decompose()
    out = {'asset': asset, 't': [round(v, 4) for v in t], 'q': [round(q.x, 5), round(q.y, 5), round(q.z, 5), round(q.w, 5)], 's': [round(v, 4) for v in s]}
    out.update(extra); return out
def point(v): return [round(v[0], 4), round(v[2], 4), round(-v[1], 4)]
def room_matrix(x, y, z, rz=0): return Matrix.Translation((x, y, z)) @ Matrix.Rotation(math.radians(rz), 4, 'Z')


def boolean(target, cutter, op='DIFFERENCE'):
    mod = target.modifiers.new('cut', 'BOOLEAN'); mod.object = cutter; mod.operation = op; mod.solver = 'EXACT'
    select([target]); bpy.context.view_layer.objects.active = target; bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def cutter_box(loc, size, bevel=.35): return rbox('cutter', loc, size, None, bevel, 4)


def island(radius=6.6):
    """The floating plot both homes stand on: a felt lawn with a scalloped edge over a rounded bank of earth."""
    p = [ball('bank', (0, 0, -.9), (radius, radius * .8, 1.2), 'Earth side', 64, 24)]
    boolean(p[0], cutter_box((0, 0, 1.5), (30, 30, 3), 0))
    p.append(ball('lawn', (0, 0, -.04), (radius + .08, radius * .8 + .08, .14), 'Grass felt', 64, 16))
    for i in range(32):
        a = i * 2 * math.pi / 32; p.append(ball('lawn scallop', ((radius - .05) * math.cos(a), (radius * .8 - .05) * math.sin(a), -.06), (.34, .34, .12), 'Grass felt', 10, 6))
    for i in range(18):
        a = i * 2 * math.pi / 18 + .2; p.append(ball('bank stone', (radius * .95 * math.cos(a), radius * .77 * math.sin(a), -.4 - .22 * (i % 3)), (.24, .2, .17), 'Stone', 10, 6))
    for i in range(150):  # tufts, wild flowers, mushrooms and stones on the lawn
        a = rng.uniform(0, 2 * math.pi); rr = radius * math.sqrt(rng.uniform(.05, .93)); x, y = rr * math.cos(a), rr * .8 * math.sin(a)
        if i % 9 == 0: p += [cyl('mushroom stem', (x, y, .14), .018, .09, 'Paper', 8), ball('mushroom cap', (x, y, .2), (.065, .055, .028), 'Petal red', 10, 6)]
        elif i % 7 == 0: p.append(ball('lawn stone', (x, y, .1), (.11, .09, .05), 'Stone', 10, 6))
        elif i % 3 == 0: p.append(ball('wild flower', (x, y, .16), (.035, .035, .025), ['Petal white', 'Petal yellow', 'Petal blue'][i % 3], 8, 5))
        else: p.append(cone('lawn tuft', (x, y, .12), .05, 0, .13, 'Grass light' if i % 2 else 'Grass deep', 5))
    for i in range(9):
        a = i * 2 * math.pi / 9 + .5; p.append(curve('hanging root', [(radius * .9 * math.cos(a), radius * .72 * math.sin(a), -.6), (radius * .8 * math.cos(a), radius * .64 * math.sin(a), -1.4), (radius * .7 * math.cos(a + .1), radius * .56 * math.sin(a + .1), -2.0)], .05, 'Root', 3))
    return p


def felt_tree(x, y, z, scale=1.0, seed=0):
    """A round felt tree: a gently curving trunk, a few boughs and clouds of leaves."""
    r = random.Random(seed); s = scale; p = []
    trunk = [(x, y, z - .2), (x + .1 * s, y, z + .9 * s), (x - .05 * s, y, z + 1.7 * s), (x + .05 * s, y, z + 2.3 * s)]
    p.append(curve('trunk', trunk, .2 * s, 'Bark', 6))
    for a in (-.9, .8, 2.4):
        p.append(curve('bough', [(x, y, z + 1.4 * s), (x + .5 * s * math.cos(a), y + .3 * s * math.sin(a), z + 1.9 * s), (x + .9 * s * math.cos(a), y + .5 * s * math.sin(a), z + 2.2 * s)], .08 * s, 'Bark', 4))
    for i, (dx, dy, dz, rr) in enumerate([(0, 0, 2.6, 1.0), (-.8, .2, 2.2, .75), (.85, .1, 2.25, .78), (-.3, -.35, 2.1, .6), (.4, -.3, 2.9, .7), (-.5, .3, 3.1, .65), (.2, .4, 3.35, .6)]):
        p.append(ball('leaf cloud', (x + dx * s, y + dy * s, z + dz * s), (rr * s, rr * .85 * s, rr * .82 * s), ['Leaf', 'Grass felt', 'Leaf dark', 'Grass light'][(i + seed) % 4], 20, 12))
    return p


# ── The burrow: a hill on the plot. A lower shoulder on the left keeps its front, with the round door in it; the
# rest of the hill's front is cut away to show the rooms.
MAIN = dict(cx=.7, rx=5.1, ry=3.4, h=6.4); SHOULDER = dict(cx=-4.0, rx=2.1, ry=2.6, h=3.3); CUT_X = -6.2
BURROW_ROOMS = {'entry': (-2.05, 0, .1), 'study': (.45, 0, .1), 'kitchen': (3.1, 0, .1), 'bedroom': (-.85, 0, 2.05), 'library': (2.35, 0, 2.05)}
DOOR_AT = (-5.72, .55); DOOR_TURN = -58  # on the hill's left flank, facing out towards the front-left
TREE_AT = (-.9, 1.25)

def dome(x, y, d, p=.62):
    r = ((x - d['cx']) / d['rx']) ** 2 + (y / d['ry']) ** 2
    return d['h'] * (1 - r) ** p if r < 1 else 0

def hill_z(x, y):
    a, b = dome(x, y, MAIN), dome(x, y, SHOULDER); m = max(a, b); k = .5
    return m + (k - abs(a - b)) ** 2 / (4 * k) if abs(a - b) < k and min(a, b) > 0 else m

def hill_height(x): return hill_z(x, 0)


def earth_texture():
    """The strata of the cutaway, following the hill: dark topsoil under the grass, loam, clay, sand, with pebbles
    and a thin stitched line between layers. u spans x −6…6, v spans z −0.5…6.8."""
    import numpy as np
    w, h = 2048, 1246; X0, X1, Z0, Z1 = -6, 6, -.5, 6.8
    xs = X0 + (X1 - X0) * (np.arange(w) + .5) / w; zs = Z0 + (Z1 - Z0) * (np.arange(h) + .5) / h
    surface = np.array([hill_height(x) for x in xs])[None, :]
    wobble = .09 * np.sin(xs[None, :] * 3.1 + zs[:, None] * .7) + .05 * np.sin(xs[None, :] * 9.7 + 1.1)
    d = surface - zs[:, None] + wobble
    layers = [(0, (0x3E, 0x2B, 0x20)), (.38, (0x68, 0x44, 0x2F)), (1.35, (0x8A, 0x58, 0x39)), (2.55, (0xA0, 0x6E, 0x47)), (3.8, (0x7A, 0x52, 0x36)), (99, None)]
    img = np.zeros((h, w, 3))
    for (lo, c), (hi, _) in zip(layers, layers[1:]):
        m = (d >= lo) & (d < hi); img[m] = np.array(c) / 255
        seam = (d >= lo) & (d < lo + .035) & (lo > 0); img[seam] *= .72  # a stitched seam between layers
    img[d < 0] = np.array((0x3E, 0x2B, 0x20)) / 255
    img *= (1 + np.random.default_rng(3).normal(0, .035, (h, w, 1)))  # felt grain
    r = np.random.default_rng(9); px = w / (X1 - X0)
    for _ in range(170):
        x, z = r.uniform(X0 + .3, X1 - .3), r.uniform(0, 6.2)
        depth = hill_height(x) - z
        if depth < .5: continue
        cx, cy = int((x - X0) * px), int((z - Z0) * px); rx_, ry_ = r.integers(5, 14), r.integers(4, 10)
        yy, xx = np.ogrid[-cy:h - cy, -cx:w - cx]; e = (xx / rx_) ** 2 + (yy / ry_) ** 2
        tone = np.array(r.choice([(0x8E, 0x81, 0x73), (0xA5, 0x98, 0x86), (0x76, 0x6B, 0x60)])) / 255
        img[e <= 1.25] *= .7; img[e <= 1] = tone; img[(e <= .35) & (yy > 0) & (xx < 0)] = np.minimum(1, tone * 1.25)
    img = np.clip(img, 0, 1) ** (1 / 2.2)
    image = bpy.data.images.new('earth_face', w, h, alpha=False)
    image.pixels.foreach_set(np.concatenate([img, np.ones((h, w, 1))], axis=2).reshape(-1).astype(np.float32))
    image.filepath_raw = str(OUT / 'earth_face.png'); image.file_format = 'PNG'; image.save()
    return image


def texture_previews(image):
    """After export: give the Blender previews the strata (exported parts carry no textures)."""
    tree = bpy.data.materials['Earth face'].node_tree; node = tree.nodes.new('ShaderNodeTexImage'); node.image = image
    tree.links.new(node.outputs['Color'], tree.nodes['Principled BSDF'].inputs['Base Color'])


def front_uv(o, X0=-6, X1=6, Z0=-.5, Z1=6.8):
    me = o.data
    if not me.uv_layers: me.uv_layers.new()
    uv = me.uv_layers.active.data
    for poly in me.polygons:
        for li in poly.loop_indices:
            v = o.matrix_world @ me.vertices[me.loops[li].vertex_index].co
            uv[li].uv = ((v.x - X0) / (X1 - X0), (v.z - Z0) / (Z1 - Z0))


def hill_solid():
    """The hill as a closed heightfield solid (it sinks below the lawn wherever the hill isn't)."""
    step = .11; xs = [-6.4 + i * step for i in range(int(12.8 / step) + 1)]; ys = [-3.3 + j * step for j in range(int(7.0 / step) + 1)]
    bm = bmesh.new(); grid = []
    for y in ys:
        row = []
        for x in xs:
            z = hill_z(x, y); row.append(bm.verts.new((x, y, z if z > .03 else -.3)))
        grid.append(row)
    for j in range(len(ys) - 1):
        for i in range(len(xs) - 1): bm.faces.new((grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]))
    top = list(bm.faces)
    ext = bmesh.ops.extrude_face_region(bm, geom=top)
    for v in [g for g in ext['geom'] if isinstance(g, bmesh.types.BMVert)]: v.co.z = -.45
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new('hill'); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new('hill', me); bpy.context.collection.objects.link(o)
    return finish(o, 'hill', H.M['Grass felt'])


def burrow_hill(dug):
    """The hill with the first `dug` rooms dug (0…5): each stage swaps in the next, so undug rooms are solid earth."""
    hill = hill_solid()
    boolean(hill, cutter_box((0, -6, 3), (20, 12, 14), 0))                                              # the cutaway: the whole front
    turn = math.radians(DOOR_TURN); out = Vector((math.sin(turn), -math.cos(turn), 0))
    alcove = cutter_box((DOOR_AT[0] + out.x * .2, DOOR_AT[1] + out.y * .2, .62), (1.5, 1.2, 1.3), .5); alcove.rotation_euler.z = turn
    boolean(hill, alcove)                                                                                # the door's alcove in the flank
    rooms = list(BURROW_ROOMS.items())[:dug]
    for room, (x, y, z) in rooms:
        W, D, Hh = SIZES[room]; boolean(hill, cutter_box((x, D / 2 - .05, z + Hh / 2 - .02), (W, D + .1, Hh + .04), .5))
    if dug >= 1: boolean(hill, cutter_box((-4.15, .42, .62), (2.9, .95, 1.1), .7))                      # the tunnel from the door to the entry, cut open
    for need, (a, b, zz) in [(2, (-1.3, -.85, .1)), (3, (1.75, 2.0, .1)), (5, (.55, .85, 2.05))]:      # tunnels between neighbours, behind the face
        if dug >= need: boolean(hill, cutter_box(((a + b) / 2, .68, zz + .52), (b - a + .5, .62, 1.0), .7))
    face, chamber, side = H.M['Earth face'], H.M['Earth chamber'], H.M['Earth side']
    hill.data.materials.clear()
    for m in (H.M['Grass felt'], face, chamber, side): hill.data.materials.append(m)
    rooms_all = list(BURROW_ROOMS.items())
    for poly in hill.data.polygons:
        c, n = poly.center, poly.normal
        if abs(c.y) < .015 and n.y < -.95: poly.material_index = 1
        elif (-.01 < c.y < 1.45 and any(abs(c.x - x) < SIZES[r][0] / 2 + .3 and z - .15 < c.z < z + SIZES[r][2] + .15 for r, (x, _, z) in rooms_all)) or (-6.2 < c.x < -2.75 and -.01 < c.y < 1.2 and c.z < 1.3):
            poly.material_index = 2
        elif n.z > .2 and c.z > -.1: poly.material_index = 0
        else: poly.material_index = 3
    for poly in hill.data.polygons: poly.use_smooth = poly.material_index in (0, 3)  # the cut and the chambers are flat
    front_uv(hill)
    return hill


def burrow_shell():
    save_home = lambda name, objs, limit=90000: H.save(OUT / 'burrow', name, objs, limit, 'burrow/' + name)
    save_home('island', island())
    for dug in range(6): save_home('hill_' + str(dug), [burrow_hill(dug)])
    # The dressing that's always there: a lip of grass along the cut, roots from the tree on top winding down
    # through the earth, rootlets under the grass, stones set in the face, and tufts on the hill.
    lip = [(x, -.03, hill_height(x) - .06) for x in [CUT_X + .05 + i * (5.75 - CUT_X) / 48 for i in range(49)]]
    decor = [curve('grass lip', lip, .1, 'Grass felt', 4)]
    for k in range(18):
        x = CUT_X + .3 + k * (8.4 / 18) + rng.uniform(-.1, .1); z = hill_height(x) - .12
        for j in range(3): decor.append(cone('lip tuft', (x + j * .07, -.06, z + .1), .04, 0, .14, 'Grass light' if j % 2 else 'Grass deep', 5))
    tx = TREE_AT[0]
    for k, (dx, drop, spread) in enumerate([(-1.2, .9, -.5), (-.4, 1.2, -.2), (.3, 1.3, .3), (1.1, .8, .7), (1.8, .6, 1.1)]):
        x0 = tx + dx * .25; z0 = hill_height(x0) - .12
        pts = [(x0, -.02, z0), (x0 + spread * .5, -.025, z0 - drop * .45), (x0 + spread * 1.1 + dx * .4, -.02, z0 - drop)]
        decor.append(curve('root', pts, .045 - .004 * k, 'Root', 4))
        decor.append(curve('rootlet', [pts[1], (pts[1][0] + .25, -.02, pts[1][2] - .3), (pts[1][0] + .3, -.02, pts[1][2] - .45)], .018, 'Root', 3))
    for k in range(26):
        x = CUT_X + .4 + k * .33; z = hill_height(x) - .15
        decor.append(curve('rootlet', [(x, -.02, z), (x + rng.uniform(-.1, .1), -.02, z - rng.uniform(.15, .35))], .012, 'Root', 3))
    busy = [(x - SIZES[r][0] / 2 - .15, x + SIZES[r][0] / 2 + .15, z - .15, z + SIZES[r][2] + .15) for r, (x, _, z) in BURROW_ROOMS.items()] + [(-6.3, -2.6, -.1, 1.5)]  # and the tunnel
    placed = 0
    while placed < 11:
        x, z = rng.uniform(CUT_X + .3, 5.4), rng.uniform(.3, 5.4)
        if z > hill_height(x) - .6 or any(a < x < b and c < z < d for a, b, c, d in busy): continue
        decor.append(ball('face stone', (x, -.015, z), (rng.uniform(.1, .2), .06, rng.uniform(.07, .13)), 'Stone', 12, 8)); placed += 1
    for k in range(70):
        x = rng.uniform(-5.8, 5.6); y = rng.uniform(.2, 3.0) if x > CUT_X else rng.uniform(-2.5, 2.8)
        z = hill_z(x, y)
        if z < .2: continue
        decor.append(cone('tuft', (x, y, z + .03), .06, 0, .16, 'Grass light' if k % 3 else 'Grass deep', 5))
    for k in range(26):  # wild flowers on the hill
        x = rng.uniform(-5.4, 5.2); y = rng.uniform(.3, 2.6) if x > CUT_X else rng.uniform(-2.3, 2.4); z = hill_z(x, y)
        if z < .25: continue
        decor.append(ball('wild flower', (x, y, z + .06), (.045, .045, .03), ['Petal white', 'Petal yellow', 'Petal pink'][k % 3], 8, 5))
    save_home('hill_decor', decor)
    tz = hill_z(*TREE_AT)
    tree = felt_tree(TREE_AT[0], TREE_AT[1], tz, .95, 1)
    tree.append(rod('swing rope', (TREE_AT[0] + 1.0, TREE_AT[1] - .2, tz + 2.6), (TREE_AT[0] + 1.0, TREE_AT[1] - .2, tz + .9), .01, 'Paper'))
    tree.append(rod('swing rope', (TREE_AT[0] + 1.4, TREE_AT[1] - .2, tz + 2.6), (TREE_AT[0] + 1.4, TREE_AT[1] - .2, tz + .9), .01, 'Paper'))
    tree.append(curve('swing bough', [(TREE_AT[0], TREE_AT[1], tz + 2.2), (TREE_AT[0] + .9, TREE_AT[1] - .1, tz + 2.6), (TREE_AT[0] + 1.6, TREE_AT[1] - .2, tz + 2.62)], .07, 'Bark', 4))
    tree.append(rbox('swing seat', (TREE_AT[0] + 1.2, TREE_AT[1] - .2, tz + .88), (.5, .16, .04), 'Honey wood', .4))
    save_home('tree', tree)
    # A chalk outline where the next room will be dug.
    for room, (x, y, z) in BURROW_ROOMS.items():
        W, D, Hh = SIZES[room]; dashes = []
        for k in range(36):
            t0, t1 = k / 36 * 2 * math.pi, (k + .55) / 36 * 2 * math.pi
            def sq(t): c, s = math.cos(t), math.sin(t); return (x + math.copysign(abs(c) ** .3, c) * (W / 2 - .08), -.03, z + Hh / 2 + math.copysign(abs(s) ** .3, s) * (Hh / 2 - .08))
            dashes.append(rod('chalk dash', sq(t0), sq(t1), .008, 'Paper'))
        save_home('outline_' + room, dashes)
    # Each room's fittings, when it's dug: a plank floor, a coloured plastered back wall and a timber frame.
    for room, (x, y, z) in BURROW_ROOMS.items():
        W, D, Hh = SIZES[room]
        p = [rbox('floor', (x, D / 2, z - .025), (W - .02, D - .04, .05), 'Plank', .2)]
        for k in range(int(W / .22)): p.append(rbox('board seam', (x - W / 2 + .22 * (k + .5), D / 2, z + .001), (.008, D - .06, .004), 'Plank dark', .2))
        p.append(rbox('plaster', (x, D - .03, z + Hh / 2), (W - .12, .04, Hh - .08), WALLS[room], .5))
        for s in (-1, 1): p.append(rbox('post', (x + s * (W / 2 - .06), .06, z + Hh / 2), (.1, .1, Hh - .05), 'Walnut', .4))
        p.append(rbox('lintel', (x, .06, z + Hh - .08), (W - .05, .12, .12), 'Walnut', .4))
        if room == 'library': p += library_shelves(room_matrix(x, y, z))
        save_home('room_' + room, p)
    save_home('garden_beds', [rbox('bed soil', (bx, by, .03), (1.1, .42, .06), 'Soil', .6) for bx, by in GARDEN_BEDS['burrow']])
    ox, oy = 2.7, 1.35; top = hill_z(ox, oy)
    p = [cyl('observatory tower', (ox, oy, top + .35), .55, 1.1, 'Stone', 28), lathe('observatory dome', [(.6, 0), (.58, .15), (.5, .35), (.32, .52), (0, .6)], 'Brass', 32)]
    p[1].location = (ox, oy, top + .9)
    p.append(rbox('observatory door', (ox - .1, oy - .54, top + .3), (.32, .06, .55), 'Door green', .4))
    p.append(cyl('observatory window', (ox + .3, oy - .47, top + .6), .1, .04, 'Window glow', 16, (math.pi / 2, 0, -.5)))
    save_home('observatory', p)


GARDEN_BEDS = {'burrow': [(.0, -1.75), (1.35, -1.75), (2.7, -1.75), (.0, -2.65), (1.35, -2.65), (2.7, -2.65)],
               'treehouse': [(-3.0, -1.4), (-3.0, -2.3), (-1.8, -3.0), (2.4, -2.0), (3.6, -1.2), (2.6, -3.0)]}


def garden_items(home):
    """600 plants and pieces for the garden stage, in order: the path, carrots row by row, the fence, greens, then flowers."""
    beds = GARDEN_BEDS[home]; items = []
    if home == 'burrow':
        path = [(-6.0 + i * .24, -.9 - .35 * math.sin(i * .2), 0) for i in range(30)]
        fence = [(-2.6 + i * .21, -4.35 + .25 * math.sin(i * .2), 0) for i in range(40)]
        crest = [(x, 1.0 + .5 * math.sin(x * 2.1), None) for x in [-5.0 + i * .33 for i in range(31)]]
        border = [(-5.6 + i * .042, -.42 - .1 * math.sin(i * .7), 0) for i in range(250)]
        tall = [(4.3 + .3 * (i % 4), -.7 - .32 * (i // 4), 0) for i in range(20)]
        gourds = [(3.9 + .32 * (i % 4), -3.0 - .32 * (i // 4), 0) for i in range(16)]
        shrubs = [(-5.8 + i * .45, -3.3 + .6 * math.sin(i * .5), 0) if i < 8 else (4.9 + .25 * math.sin(i), -1.6 - (i - 8) * .18, 0) for i in range(24)]
    else:
        path = [(.3 + .2 * math.sin(i * .3), -4.8 + i * .12, 0) for i in range(30)]
        fence = [(4.6 * math.cos(a), 3.6 * math.sin(a), 0) for a in [math.pi * (1.1 + i * .8 / 40) for i in range(40)]]
        crest = [(1.9 * math.cos(a) + .3, 1.9 + 1.2 * math.sin(a), 0) for a in [i * 2 * math.pi / 31 for i in range(31)]]
        border = [((2.0 + .06 * (i % 5)) * math.cos(i * 6 * math.pi / 250) + .3, (1.7 + .06 * (i % 5)) * math.sin(i * 6 * math.pi / 250) + 1.2, 0) for i in range(250)]
        tall = [(-1.3 + i * .16, 3.2, 0) for i in range(20)]
        gourds = [(-3.8 + .32 * (i % 4), -.3 - .3 * (i // 4), 0) for i in range(16)]
        shrubs = [(5.0 * math.cos(i * .26 + 3.4), 3.9 * math.sin(i * .26 + 3.4), 0) for i in range(24)]
    for x, y, z in path: items.append({'asset': 'stepping_stone', 'm': Matrix.Translation((x, y, .005)) @ Matrix.Rotation(rng.uniform(0, 3), 4, 'Z')})
    for b, (bx, by) in enumerate(beds):
        kind, per = ('carrot', 12) if b < 4 else (('cabbage', 6) if b == 4 else ('lettuce', 8))
        for r in range(3):
            for c in range(per):
                items.append({'asset': kind, 'm': Matrix.Translation((bx - .45 + c * .9 / (per - 1), by - .12 + r * .12, .06)) @ Matrix.Rotation(rng.uniform(0, 6), 4, 'Z')})
    for x, y, z in fence: items.append({'asset': 'fence_post', 'm': Matrix.Translation((x, y, 0)) @ Matrix.Rotation(math.atan2(y, x) + math.pi / 2 if home == 'treehouse' else 0, 4, 'Z')})
    extras = {50: 'scarecrow', 220: 'birdhouse', 400: 'watering_can'}
    flowers = [(p, 'flower_' + 'abcde'[i % 5]) for i, p in enumerate(border)]
    tops = [(p, 'flower_' + 'cdbae'[i % 5]) for i, p in enumerate(crest)]
    fl, sh, ta, go, to = list(flowers), [(p, 'bush') for p in shrubs], [(p, 'sunflower') for p in tall], [(p, 'pumpkin') for p in gourds], list(tops)
    rest = []
    while fl or sh or ta or go or to:
        for source, n in ((fl, 8), (sh, 1), (ta, 1), (go, 1), (to, 1)):
            for _ in range(n):
                if source: rest.append(source.pop(0))
    for (x, y, z), asset in rest:
        if z is None: z = hill_z(x, y)
        items.append({'asset': asset, 'm': Matrix.Translation((x, y, z)) @ Matrix.Rotation(rng.uniform(-.4, .4), 4, 'Z')})
    spots = {'burrow': {'scarecrow': (1.35, -2.2, 0), 'birdhouse': (-4.6, -2.4, 0), 'watering_can': (.7, -1.25, 0)},
             'treehouse': {'scarecrow': (-2.4, -1.85, 0), 'birdhouse': (4.0, -.3, 0), 'watering_can': (1.6, -1.6, 0)}}[home]
    out = []
    for it in items:
        if len(out) in extras: out.append({'asset': extras[len(out)], 'm': Matrix.Translation(spots[extras[len(out)]]) @ Matrix.Rotation(-.3, 4, 'Z')})
        out.append(it)
    assert len(out) == 600, len(out)
    return out


# ── The treehouse: a great felt tree, with a painted cabin for each room built up around it.
TREE_ROOMS = {'entry': (-1.45, -.3, 1.1), 'study': (2.1, -.3, 1.3), 'kitchen': (-1.9, -.3, 3.5), 'bedroom': (2.2, -.3, 3.95), 'library': (.3, -.3, 6.6)}  # roofs clear the floors above
TRUNK = (.3, 1.85); PITCH = math.radians(22)

def trunk_radius(z): return max(.3, .78 - .05 * z)
def trunk_x(z): return TRUNK[0] + .12 * math.sin(z / 2.6)


def cabin(room, x, y, z):
    """A painted cabin with an open front: platform, walls, a gable roof, a round window and a flower box."""
    W, D, Hh = SIZES[room]; wall, roof = WALLS[room], ROOFS[room]; c = []
    c.append(rbox('platform', (x, y + D / 2, z - .06), (W + .5, D + .5, .12), 'Plank', .2))
    for k in range(int((W + .5) / .2)): c.append(rbox('platform seam', (x - (W + .5) / 2 + .2 * (k + .5), y + D / 2, z + .002), (.008, D + .45, .004), 'Plank dark', .2))
    c.append(rbox('back wall', (x, y + D - .035, z + Hh / 2), (W, .07, Hh), wall, .15))
    for s in (-1, 1):
        c.append(rbox('side wall', (x + s * (W / 2 - .035), y + D / 2, z + Hh / 2), (.07, D, Hh), wall, .15))
        c.append(rbox('corner post', (x + s * W / 2, y + .04, z + Hh / 2), (.12, .12, Hh + .04), 'Trim', .4))
        c.append(rbox('back corner', (x + s * W / 2, y + D - .04, z + Hh / 2), (.12, .12, Hh + .04), 'Trim', .4))
    half = W / 2 + .28; rise = half * math.tan(PITCH); L = half / math.cos(PITCH) + .02
    for s in (-1, 1):
        panel = rbox('roof', (0, 0, 0), (L, D + .6, .1), roof, .3); panel.rotation_euler.y = s * PITCH
        panel.location = (x + s * half / 2, y + D / 2, z + Hh + rise / 2 + .08); c.append(panel)
        for k in range(4):  # shingle courses
            t = (k + .5) / 4; course = rbox('shingle course', (0, 0, 0), (.03, D + .62, .04), 'Shingle', .5); course.rotation_euler.y = s * PITCH
            course.location = (x + s * (half * t), y + D / 2, z + Hh + rise * (1 - t) + .14); c.append(course)
    me = bpy.data.meshes.new('gable'); bm = bmesh.new()
    for yy in (y + D - .07, y + D):
        vs = [bm.verts.new((x - W / 2, yy, z + Hh)), bm.verts.new((x + W / 2, yy, z + Hh)), bm.verts.new((x, yy, z + Hh + rise * (W / 2) / half))]
        bm.faces.new(vs if yy > y + D - .05 else vs[::-1])
    bm.to_mesh(me); bm.free(); g = bpy.data.objects.new('gable', me); bpy.context.collection.objects.link(g); c.append(finish(g, 'gable', H.M[wall]))
    c.append(rbox('ridge beam', (x, y + D / 2, z + Hh + rise + .12), (.12, D + .64, .12), 'Walnut', .4))
    c.append(rbox('front beam', (x, y + .04, z + Hh + .02), (W + .12, .12, .1), 'Trim', .4))
    c.append(cyl('round window', (x - W / 2 - .02, y + D / 2, z + Hh * .6), .17, .05, 'Window glow', 20, (0, math.pi / 2, 0)))
    c.append(cyl('window rim', (x - W / 2 - .04, y + D / 2, z + Hh * .6), .2, .03, 'Trim', 20, (0, math.pi / 2, 0)))
    c.append(rbox('flower box', (x + W / 2 + .06, y + D / 2, z + Hh * .45), (.12, .5, .12), 'Honey wood', .3))
    for k in range(4): c.append(ball('box flower', (x + W / 2 + .08, y + D / 2 - .18 + k * .12, z + Hh * .45 + .1), (.045, .045, .04), ['Petal red', 'Petal yellow', 'Petal white', 'Petal pink'][k], 8, 5))
    for s in (-1, 1):  # brackets back to the tree
        c.append(rod('bracket', (x + s * (W / 2 - .15), y + D - .05, z - .12), (x + s * (W / 2 - .6), y + D + .35, z - 1.0), .05, 'Walnut'))
    return c


def treehouse_shell():
    save_home = lambda name, objs, limit=90000: H.save(OUT / 'treehouse', name, objs, limit, 'treehouse/' + name)
    save_home('island', island())
    ty = TRUNK[1]
    prof = [(1.25, 0), (1.0, .08), (.88, .28), (.8, .6)] + [(trunk_radius(z), z) for z in [1.2, 2.4, 3.6, 4.8, 6.0, 7.2, 8.4, 9.6, 10.4]] + [(.2, 10.8), (0, 10.9)]
    trunk = lathe('trunk', prof, 'Bark', 36)
    for v in trunk.data.vertices: v.co.x += trunk_x(v.co.z); v.co.y += ty
    p = [trunk]
    for i in range(7):  # roots
        a = -.35 - i * (math.pi + .7) / 6
        p.append(curve('root', [(TRUNK[0] + .65 * math.cos(a), ty + .65 * math.sin(a), .55), (TRUNK[0] + 1.3 * math.cos(a), ty + 1.15 * math.sin(a), .13), (TRUNK[0] + 1.85 * math.cos(a), ty + 1.55 * math.sin(a), .02)], .17, 'Bark', 5))
    for i in range(16):  # bark ribs
        a = i * 2 * math.pi / 16; z0 = rng.uniform(.4, 4.0); z1 = z0 + rng.uniform(1.0, 2.2)
        p.append(curve('bark rib', [(trunk_x(z0) + (trunk_radius(z0) + .01) * math.cos(a), ty + (trunk_radius(z0) + .01) * math.sin(a), z0), (trunk_x(z1) + (trunk_radius(z1) + .01) * math.cos(a + .12), ty + (trunk_radius(z1) + .01) * math.sin(a + .12), z1)], .035, 'Bark light', 3))
    # A bough under each cabin, carrying it; more up into the crown.
    for room, (x, y, z) in TREE_ROOMS.items():
        W, D, Hh = SIZES[room]; side = 1 if x > TRUNK[0] else -1
        p.append(curve('carrying bough', [(trunk_x(z - 1.2), ty, z - 1.3), (x - side * W * .1, ty - .3, z - .7), (x + side * W * .3, y + D * .7, z - .2)], .15, 'Bark', 5))
    for a, b in [((0, 0, 7.4), (-2.9, 2.6, 9.3)), ((0, 0, 7.8), (3.4, 2.4, 9.6)), ((0, 0, 9.0), (-1.3, 2.9, 11.0)), ((0, 0, 9.4), (2.1, 2.7, 11.3))]:
        a = (trunk_x(a[2]), ty, a[2]); p.append(curve('bough', [a, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + .2, (a[2] + b[2]) / 2 + .3), b], .15, 'Bark', 5))
    crown = []
    for i, (x, y, z, r) in enumerate([(-2.9, 2.7, 9.4, 1.6), (3.5, 2.5, 9.7, 1.7), (-1.2, 3.0, 11.1, 1.8), (2.1, 2.9, 11.4, 1.7), (.4, 3.3, 12.0, 1.6), (-3.8, 2.2, 7.9, 1.2), (4.3, 2.1, 8.2, 1.3), (.5, 3.4, 10.1, 1.8), (-2.3, 3.4, 10.6, 1.4), (3.5, 3.3, 10.9, 1.3)]):
        crown.append(ball('leaf cloud', (x, y, z), (r, r * .8, r * .82), ['Leaf', 'Leaf dark', 'Grass felt', 'Grass deep'][i % 4], 22, 14))
        for k in range(5):
            a = k * 1.3 + i; crown.append(ball('leaf puff', (x + r * .85 * math.cos(a), y - .35, z + r * .6 * math.sin(a)), (r * .42, r * .36, r * .38), ['Grass light', 'Leaf', 'Grass felt'][(i + k) % 3], 14, 9))
    for room, (x, y, z) in TREE_ROOMS.items():  # leafy clusters beside each cabin, so it's a living tree all the way up
        W, D, Hh = SIZES[room]; side = 1 if x > TRUNK[0] else -1
        for k, (dx, dz, rr) in enumerate([(.35, .2, .42), (.55, .75, .34), (.2, -.35, .3)]):
            crown.append(ball('leaf cluster', (x + side * (W / 2 + dx), y + D + .15, z + Hh * .5 + dz), (rr, rr * .8, rr * .85), ['Leaf', 'Grass felt', 'Leaf dark'][k], 14, 9))
    save_home('tree', p); save_home('crown', crown)
    for room, (x, y, z) in TREE_ROOMS.items():
        c = cabin(room, x, y, z)
        if room == 'library': c += library_shelves(room_matrix(x, y, z))
        save_home('room_' + room, c)
    stair = []
    for k in range(80):  # a spiral stair of planks around the trunk, from the roots up to the library
        a = -.3 + k * .36; z = .15 + k * .07; r = trunk_radius(z) + .3
        s = rbox('step', (trunk_x(z) + r * math.cos(a), ty + r * math.sin(a), z), (.44, .2, .05), 'Plank', .3); s.rotation_euler.z = a + math.pi / 2; stair.append(s)
        if k % 3 == 0: stair.append(rod('stair post', (trunk_x(z) + (r + .2) * math.cos(a), ty + (r + .2) * math.sin(a), z), (trunk_x(z) + (r + .2) * math.cos(a), ty + (r + .2) * math.sin(a), z + .5), .02, 'Walnut'))
    rail = []
    for k in range(0, 80, 2):
        a = -.3 + k * .36; z = .15 + k * .07; r = trunk_radius(z) + .5; rail.append((trunk_x(z) + r * math.cos(a), ty + r * math.sin(a), z + .5))
    for i in range(0, len(rail) - 1, 8): stair.append(curve('handrail', rail[i:i + 9], .018, 'Walnut', 4))
    save_home('stair', stair)
    save_home('garden_beds', [rbox('bed soil', (bx, by, .03), (1.1, .42, .06), 'Soil', .6) for bx, by in GARDEN_BEDS['treehouse']])
    nx, ny, nz = trunk_x(10.1), ty - .1, 10.1
    p = [cyl('nest floor', (nx, ny, nz), .95, .12, 'Plank', 24)]
    for k in range(14):
        a = k * 2 * math.pi / 14; p.append(rod('nest post', (nx + .85 * math.cos(a), ny + .85 * math.sin(a), nz), (nx + .85 * math.cos(a), ny + .85 * math.sin(a), nz + .5), .025, 'Walnut'))
    p.append(curve('nest rail', [(nx + .85 * math.cos(k * math.pi / 12), ny + .85 * math.sin(k * math.pi / 12), nz + .5) for k in range(25)], .03, 'Walnut', 3))
    for k in range(4):
        a = k * math.pi / 2 + .4; p.append(rod('nest roof post', (nx + .75 * math.cos(a), ny + .75 * math.sin(a), nz), (nx + .75 * math.cos(a), ny + .75 * math.sin(a), nz + 1.0), .03, 'Walnut'))
    p.append(cone('nest roof', (nx, ny, nz + 1.3), 1.15, .05, .6, 'Roof teal', 18))
    save_home('observatory', p)


# ── Assemble each home's layout: what's always there, and each stage's structure and items in order.
def home_layout(home):
    rooms = BURROW_ROOMS if home == 'burrow' else TREE_ROOMS
    base = ['island', 'hill_decor', 'tree'] if home == 'burrow' else ['island', 'tree', 'crown', 'stair']
    stages = []
    if home == 'burrow':
        door = room_matrix(DOOR_AT[0], DOOR_AT[1], 0, DOOR_TURN)
        items = [('round_door', door), ('lantern_post', door @ Matrix.Translation((.95, -.45, 0))), ('mailbox', door @ Matrix.Translation((-.9, -.5, 0)))]
    else:
        door = room_matrix(trunk_x(.5), TRUNK[1] - trunk_radius(.5) - .02, 0, 0)
        items = [('round_door', door @ Matrix.Diagonal((.8, .8, .8, 1))), ('lantern_post', door @ Matrix.Translation((1.0, -.5, 0))), ('mailbox', door @ Matrix.Translation((-1.05, -.55, 0)))]
    stages.append({'threshold': 0, 'room': 'door', 'structure': [], 'items': [slot(a, m) for a, m in items]})
    builders = {'entry': entry_items, 'study': study_items, 'kitchen': kitchen_items, 'bedroom': bedroom_items, 'library': library_items}
    for s, room in enumerate(ROOMS[1:6], start=1):
        x, y, z = rooms[room]; R = room_matrix(x, y - BACK, z); W, D, Hh = SIZES[room]
        stage = {'threshold': THRESHOLDS[s], 'room': room, 'structure': [slot('room_' + room, Matrix.Identity(4), home=home)],
                 'light': point(Vector((x + W / 2 - .5, y + D * .5, z + Hh - .3))), 'items': [slot(it['asset'], R @ it['m']) for it in builders[room]()]}
        if home == 'burrow': stage['outline'] = [slot('outline_' + room, Matrix.Identity(4), home=home)]
        stages.append(stage)
    stages.append({'threshold': THRESHOLDS[6], 'room': 'garden', 'structure': [slot('garden_beds', Matrix.Identity(4), home=home)], 'items': [slot(it['asset'], it['m']) for it in garden_items(home)]})
    scope = room_matrix(2.7, .72, hill_z(2.7, 1.35) + 1.3, 180) if home == 'burrow' else room_matrix(trunk_x(10.1), TRUNK[1] - .35, 10.17, 180)
    stages.append({'threshold': THRESHOLDS[7], 'room': 'observatory', 'structure': [slot('observatory', Matrix.Identity(4), home=home)], 'items': [slot('telescope', scope)]})
    def at(room, x, y, z, rz=0):
        rx, ry, rzz = rooms[room]; return point(Vector((rx + x, ry - BACK + y, rzz + z))) + [rz]
    # 'door' is outside the front door; 'drift' is where Moku waits for you once there's a way in (in the burrow,
    # the mouth of the tunnel from the door, so it's in view).
    outside = point(door @ Vector((0, -.8, 0))) + [0]
    moku = {'focus': at('study', .1, 1.0, .37), 'break': at('kitchen', .3, 1.02, .33), 'away': at('bedroom', .75, .75, .4),
            'early': at('entry', 0, .62, .02), 'door': outside, 'drift': point(Vector((-3.55, .5, .05))) + [0] if home == 'burrow' else outside}
    garland, tags = garland_path(home, rooms)
    layout_home = {'base': [slot(b, Matrix.Identity(4), home=home) for b in base], 'stages': stages, 'moku': moku,
                   'garland': [point(v) for v in garland], 'bulbs': [slot('bulb', m, stage=tag) for m, tag in bulbs_along(garland, tags, 200)],
                   'stars': [point(Vector((rng.uniform(-10, 10), rng.uniform(8, 13), rng.uniform(4.5, 14)))) for _ in range(1500)], 'cameras': cameras(home)}
    if home == 'burrow': layout_home['terrain'] = [slot('hill_' + str(k), Matrix.Identity(4), home=home) for k in range(6)]
    return layout_home


def garland_path(home, rooms):
    """The garland the lanterns hang on: along the ground floor left to right, up, and back along the upper floor.
    Each point is tagged with the stage of the room it hangs in (a swag between two rooms needs both), so a lantern
    is lit only once its room exists."""
    stage_of = {r: ROOMS.index(r) for r in SIZES}
    def ends(room, rev=False):
        x, y, z = rooms[room]; W, D, Hh = SIZES[room]; a, b = Vector((x - W / 2 + .15, y + .12, z + Hh - .14)), Vector((x + W / 2 - .15, y + .12, z + Hh - .14))
        return [(b, stage_of[room]), (a, stage_of[room])] if rev else [(a, stage_of[room]), (b, stage_of[room])]
    if home == 'burrow':
        anchors = [(Vector((-5.0, .12, 1.05)), 1), (Vector((-3.3, .12, 1.05)), 1)] + ends('entry') + ends('study') + ends('kitchen') + ends('library', True) + ends('bedroom', True)
    else:
        anchors = [(Vector((trunk_x(.5) + 1.0, TRUNK[1] - 1.2, 1.05)), 1)] + ends('entry') + ends('study') + ends('bedroom', True) + ends('kitchen', True) + ends('library')
    pts, tags = [], []
    for (a, ta), (b, tb) in zip(anchors, anchors[1:]):
        n = max(4, int((b - a).length / .12))
        for k in range(n):
            t = k / n; p = a.lerp(b, t); p.z -= .2 * math.sin(math.pi * t) * min(1, (b - a).length / 1.2); pts.append(p); tags.append(max(ta, tb))
    pts.append(anchors[-1][0]); tags.append(anchors[-1][1])
    return pts, tags


def bulbs_along(path, tags, count):
    lengths = [0]
    for a, b in zip(path, path[1:]): lengths.append(lengths[-1] + (b - a).length)
    total = lengths[-1]; out = []; k = 0
    for i in range(count):
        d = (i + .5) / count * total
        while k < len(path) - 2 and lengths[k + 1] < d: k += 1
        t = (d - lengths[k]) / max(1e-6, lengths[k + 1] - lengths[k]); out.append((Matrix.Translation(path[k].lerp(path[k + 1], t)), tags[k]))
    return out


def cameras(home):
    """The view grows with the home, framing what's built and the next room. Front-right, a little above."""
    if home == 'burrow':
        frames = [(0, (-5.1, -.4, 1.0), 9.2), (30, (-1.9, 0, 1.0), 9.6), (300, (-1.5, 0, 1.6), 11.6), (600, (-.7, 0, 2.5), 13.6), (1500, (-.5, 0, 2.9), 14.8), (4000, (-.5, -1.2, 2.8), 16.4), (10000, (-.4, -.9, 3.8), 18.0)]
    else:
        frames = [(0, (.4, 0, 1.8), 10.8), (300, (.3, 0, 3.0), 13.0), (600, (.3, 0, 3.9), 14.4), (1500, (.3, 0, 5.7), 18.2), (4000, (.3, -1.0, 5.5), 19.4), (10000, (.3, -.6, 6.8), 21.2)]
    direction = Vector((-.36, -1.0, .40)).normalized()
    return [{'threshold': t, 'target': point(Vector(c)), 'from': point(Vector(c) + direction * d)} for t, c, d in frames]


# ── Build everything.
strata = earth_texture()
H.build_all(KIT)
burrow_shell(); treehouse_shell()
layout = {'schemaVersion': 1, 'thresholds': THRESHOLDS, 'rooms': ROOMS, 'pointsPerItem': 10,
          'note': 'RealityKit space (y up, front +z). Kit parts: world/home/kit/<asset>.usdz; a slot with "home" is world/home/<home>/<asset>.usdz. '
                  'terrain[k] replaces the hill once k rooms are dug.',
          'homes': {h: home_layout(h) for h in ('burrow', 'treehouse')}}
(OUT / 'layout.json').write_text(json.dumps(layout) + '\n')
(OUT / 'materials.json').write_text(json.dumps({'materials': H.material_rules()}, indent=1) + '\n')
(OUT / 'manifest.json').write_text(json.dumps({'parts': H.MANIFEST}, indent=1) + '\n')
print('HOME KIT', len(H.MANIFEST), 'parts;', {h: sum(len(s['items']) for s in layout['homes'][h]['stages']) for h in layout['homes']}, 'items')


# ── Previews: each home at a few ages, composed from the layout exactly as the app will, rendered in EEVEE.
CI = C.inverted()
def blender_matrix(s):
    q = Quaternion((s['q'][3], s['q'][0], s['q'][1], s['q'][2]))
    return CI @ Matrix.LocRotScale(Vector(s['t']), q, Vector(s['s'])) @ C
def blender_point(p): return Vector((p[0], -p[2], p[1]))


def visible(home, points, returns):
    """(asset key, Blender matrix) for everything on show after `points` focused minutes and `returns` returns."""
    L = layout['homes'][home]; key = lambda s: (home + '/' + s['asset']) if 'home' in s else s['asset']
    out = [(key(s), blender_matrix(s)) for s in L['base']]; lights = []
    opened = sum(1 for t in THRESHOLDS[1:6] if points >= t)
    if 'terrain' in L: out.append((key(L['terrain'][opened]), blender_matrix(L['terrain'][opened])))
    upcoming = next((k for k, t in enumerate(THRESHOLDS) if t > points), None)
    for i, st in enumerate(L['stages']):
        nxt = THRESHOLDS[i + 1] if i + 1 < len(THRESHOLDS) else None
        if points < st['threshold']:
            if i == upcoming: out += [(key(s), blender_matrix(s)) for s in st.get('outline', [])]
            continue
        out += [(key(s), blender_matrix(s)) for s in st['structure']]
        if 'light' in st: lights.append(blender_point(st['light']))
        n = len(st['items']) if nxt is not None and points >= nxt else int((points - st['threshold']) // 10)
        out += [(key(s), blender_matrix(s)) for s in st['items'][:n]]
    opened = max(i for i, t in enumerate(THRESHOLDS) if points >= t)
    out += [('bulb', blender_matrix(s)) for s in [b for b in L['bulbs'] if b['stage'] <= opened][:returns]]
    out += [('star', Matrix.Translation(blender_point(p))) for p in L['stars'][:max(0, int((points - THRESHOLDS[7]) // 10))]]
    return out, lights


MOKU = None
def moku_at(anchor):
    global MOKU
    if MOKU is None:
        before = set(bpy.data.objects)
        bpy.ops.wm.usd_import(filepath=str(ROOT / 'character/moku_bunny.usdz'))
        new = [o for o in bpy.data.objects if o not in before]
        MOKU = bpy.data.objects.new('moku', None); bpy.context.collection.objects.link(MOKU)
        for o in new:
            if o.parent is None: o.parent = MOKU
    MOKU.location = blender_point(anchor[:3]); MOKU.rotation_euler = (0, 0, math.radians(anchor[3]))


def render_preview(home, points, returns, label, state='focus'):
    scene = bpy.context.scene
    for o in list(bpy.data.objects):
        if o.get('preview'): bpy.data.objects.remove(o, do_unlink=True)
    shown, lights = visible(home, points, returns)
    for key, m in shown:
        o = H.PARTS[key].copy(); o['preview'] = True; o.matrix_world = m; o.hide_render = False
        bpy.context.collection.objects.link(o); o.hide_set(False)
    for p in lights:
        bpy.ops.object.light_add(type='POINT', location=p); l = bpy.context.object; l['preview'] = True
        l.data.energy = 70; l.data.color = (1, .76, .48); l.data.shadow_soft_size = .3
    L = layout['homes'][home]
    moku_at(L['moku']['focus'] if points >= THRESHOLDS[2] else L['moku']['early'])
    cam = [c for c in L['cameras'] if c['threshold'] <= points][-1]
    target, eye = blender_point(cam['target']), blender_point(cam['from'])
    if 'Camera' not in bpy.data.objects:
        bpy.ops.object.camera_add(); bpy.context.object.name = 'Camera'
        for name, energy, colour, frm in [('Sun', 3.4, (1, .87, .72), (3, -5, 6)), ('Fill', 1.0, (.7, .78, 1), (-4, -2, 3)), ('Rim', 1.4, (1, .8, .6), (-1, 5, 4))]:
            bpy.ops.object.light_add(type='SUN'); l = bpy.context.object; l.name = name; l.data.energy = energy; l.data.color = colour; l.data.angle = .15
            l.rotation_euler = (Vector((0, 0, 0)) - Vector(frm)).to_track_quat('-Z', 'Y').to_euler()
    camo = bpy.data.objects['Camera']; camo.location = eye; camo.rotation_euler = (target - eye).to_track_quat('-Z', 'Y').to_euler()
    camo.data.lens_unit = 'FOV'; camo.data.angle = math.radians(30); camo.data.sensor_fit = 'HORIZONTAL'; scene.camera = camo
    scene.render.engine = 'BLENDER_EEVEE'; scene.render.resolution_x = 800; scene.render.resolution_y = 760; scene.render.film_transparent = True
    scene.view_settings.view_transform = 'AgX'; scene.eevee.taa_render_samples = 32; scene.world.color = (.33, .32, .40)
    scene.render.filepath = str(PRE / f'{home}_{label}.png'); bpy.ops.render.render(write_still=True)


if '--previews' in sys.argv:
    texture_previews(strata)
    for home in ('burrow', 'treehouse'):
        for points, returns, label in [(180, 6, 'day1'), (1200, 40, 'week1'), (12000, 200, 'month3')]:
            render_preview(home, points, returns, label)
    print('HOME PREVIEWS', PRE)
