"""Today's tree: one felt tree a day, grown and built with focused minutes (Charles, 2026-09-29).

Every 10 focused minutes adds a piece; the day's goal (4 hours by default) finishes the treehouse:
  0-2 h   the tree grows: a seed, a sapling, a young tree, a grown tree (the first celebration, at 2 h)
  2-4 h   the treehouse, one piece at a time: brackets, deck, ladder, rail, walls, door, window, roof, lights
  4-6 h   extras: a swing, a bird house, bunting, a telescope, a hammock, a kite...
  6-8 h   grand extras: a crow's nest, a slide, a zipline, a balloon, string lights...
  8 h+    a new star in the sky every 10 minutes
Returns light lanterns in the tree. The layout uses the home's schema (HomeLayout in HomeWorld.swift), so the
app's renderer draws it as it draws the home; shared items come from world/home/kit.

Run: Blender --background --factory-startup --python-exit-code 1 --python assets/src/tree_kit.py"""
import sys, math, json, random
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ROOT, reset, finish
import home_parts as H
from home_parts import rbox, ball, cyl, cone, rod, curve, lathe
import bpy, bmesh
from mathutils import Vector, Matrix, Euler

OUT = ROOT / 'world/daytree'; OUT.mkdir(parents=True, exist_ok=True)
reset(); H.materials(ROOT); rng = random.Random(11)

THRESHOLDS = [0, 30, 60, 90, 120, 240, 360, 480]
STAGES = ['seed', 'sapling', 'young tree', 'tree', 'treehouse', 'extras', 'grand extras', 'stars']
TREE = (0.0, 0.55)           # the trunk's foot (x, y); the plot's front is -y
DECK = (1.05, 0.45, 2.05)    # the treehouse deck's centre and height
DW, DD = 1.9, 1.5            # deck width and depth
CW, CD, CH = 1.4, 1.05, 1.15 # the cabin
NEST_Z = 5.15                # the crow's nest, on a mast above the crown

C = Matrix.Rotation(-math.pi / 2, 4, 'X')
def slot(asset, m=None, home='daytree', **extra):
    m = m or Matrix.Identity(4)
    t, q, s = (C @ m @ C.inverted()).decompose()
    out = {'asset': asset, 't': [round(v, 4) for v in t], 'q': [round(q.x, 5), round(q.y, 5), round(q.z, 5), round(q.w, 5)], 's': [round(v, 4) for v in s]}
    if home: out['home'] = home
    out.update(extra); return out
def kit(asset, x, y, z=0, rz=0, s=1): return slot(asset, M(x, y, z, rz, s), home=None)
def M(x, y, z=0, rz=0, s=1): return Matrix.Translation((x, y, z)) @ Matrix.Rotation(math.radians(rz), 4, 'Z') @ Matrix.Diagonal((s, s, s, 1))
def point(v): return [round(v[0], 4), round(v[2], 4), round(-v[1], 4)]
def part(name, objs, limit=30000): H.save(OUT, name, objs, limit); return name

def trunk_x(z): return TREE[0] + .06 * math.sin(z * 1.3)

# ── The plot: a small round felt lawn over a bank of earth, with a path to the front.
def plot(radius=3.4):
    p = [ball('bank', (0, 0, -.64), (radius, radius * .85, .6), 'Earth side', 56, 20)]  # its top stays under the lawn
    p.append(ball('lawn', (0, 0, -.03), (radius + .06, radius * .85 + .06, .12), 'Grass felt', 56, 14))
    for i in range(26):
        a = i * 2 * math.pi / 26; p.append(ball('scallop', ((radius - .04) * math.cos(a), (radius * .85 - .04) * math.sin(a), -.05), (.26, .26, .1), 'Grass felt', 10, 6))
    for i in range(12):
        a = i * 2 * math.pi / 12 + .3; p.append(ball('bank stone', (radius * .96 * math.cos(a), radius * .82 * math.sin(a), -.32 - .15 * (i % 3)), (.18, .15, .13), 'Stone', 10, 6))
    for k in range(6):  # the path to the tree
        p.append(ball('path stone', (-.15 + .12 * math.sin(k), -2.7 + k * .42, .02), (.2, .15, .035), 'Pebble', 12, 6))
    for i in range(70):
        a = rng.uniform(0, 2 * math.pi); rr = radius * math.sqrt(rng.uniform(.12, .92)); x, y = rr * math.cos(a), rr * .85 * math.sin(a)
        if abs(x) < .45 and y < -.2: continue  # keep the path clear
        if i % 8 == 0: p += [cyl('mushroom stem', (x, y, .1), .014, .07, 'Paper', 8), ball('mushroom cap', (x, y, .15), (.05, .045, .022), 'Petal red', 10, 6)]
        elif i % 3 == 0: p.append(ball('wild flower', (x, y, .12), (.028, .028, .02), ['Petal white', 'Petal yellow', 'Petal blue'][i % 3], 8, 5))
        else: p.append(cone('tuft', (x, y, .09), .04, 0, .1, 'Grass light' if i % 2 else 'Grass deep', 5))
    return p

# ── The tree, in five sizes (a swap as it grows).
def mound():
    x, y = TREE
    return [ball('mound', (x, y, .0), (.5, .44, .16), 'Soil', 24, 12), ball('mound top', (x, y, .1), (.34, .3, .08), 'Earth side', 18, 8)]

def leaves_pair(x, y, z, size, turn, material='Leaf'):
    out = []
    for s in (-1, 1):
        leaf = ball('leaf', (0, 0, 0), (size, size * .45, size * .12), material, 12, 6)
        leaf.location = (x + s * size * .8 * math.cos(turn), y + s * size * .8 * math.sin(turn), z); leaf.rotation_euler = (0, s * -.5, turn); out.append(leaf)
    return out

def tree_seed():
    x, y = TREE
    p = mound() + [ball('seed', (x + .1, y - .06, .14), (.05, .035, .03), 'Walnut', 10, 6)]
    p.append(curve('sprout', [(x, y, .12), (x + .01, y, .22), (x - .01, y, .3)], .012, 'Leaf', 4))
    return p + leaves_pair(x - .01, y, .31, .06, .3, 'Grass light')

def tree_sapling():
    x, y = TREE
    p = mound() + [curve('stem', [(x, y, .1), (x + .03, y, .45), (x - .02, y, .8), (x, y, 1.05)], .025, 'Bark light', 5)]
    for k, z in enumerate((.42, .62, .8, .95, 1.07)): p += leaves_pair(x, y, z, .1 + .02 * (k % 2), k * 1.1, ['Leaf', 'Grass light'][k % 2])
    return p

def trunk(height, base, top, boughs, crown):
    x, y = TREE
    prof = [(base * 1.5, 0), (base * 1.15, .08), (base, .3)] + [(base + (top - base) * (z / height), z) for z in (height * .3, height * .6, height * .85)] + [(top * .6, height), (0, height + .05)]
    t = lathe('trunk', prof, 'Bark', 28)
    for v in t.data.vertices: v.co.x += trunk_x(v.co.z); v.co.y += y
    p = [t]
    for i in range(5 if base > .2 else 3):
        a = -.2 - i * (math.pi + .4) / 4
        p.append(curve('root', [(x + base * .8 * math.cos(a), y + base * .8 * math.sin(a), base * 1.2), (x + base * 1.9 * math.cos(a), y + base * 1.7 * math.sin(a), .08), (x + base * 2.6 * math.cos(a), y + base * 2.3 * math.sin(a), .0)], base * .35, 'Bark', 4))
    for (z0, a, length, r) in boughs:
        p.append(curve('bough', [(trunk_x(z0), y, z0), (trunk_x(z0) + length * .5 * math.cos(a), y + .12, z0 + length * .35), (trunk_x(z0) + length * math.cos(a), y + .18, z0 + length * .5 * (1 + math.sin(a) * .3))], r, 'Bark', 5))
    for i, (dx, dy, dz, rr) in enumerate(crown):
        p.append(ball('leaf cloud', (x + dx, y + dy, dz), (rr, rr * .82, rr * .8), ['Leaf', 'Grass felt', 'Leaf dark', 'Grass light'][i % 4], 18, 11))
    return p

def tree_young():
    return trunk(2.0, .12, .05, [(1.2, .4, .7, .04), (1.45, 2.7, .65, .04), (1.7, 1.2, .5, .035)],
                 [(0, .1, 2.05, .55), (-.45, .15, 1.8, .42), (.5, .1, 1.85, .44), (.1, .2, 2.45, .42)])

GROWN_BOUGHS = [(1.75, -.15, 1.35, .09), (2.2, 3.3, 1.2, .08), (2.6, .5, 1.0, .07), (2.9, 2.4, .95, .07), (3.2, 1.4, .7, .06)]
GROWN_CROWN = [(0, .15, 3.75, 1.05), (-1.05, .2, 3.25, .85), (1.1, .15, 3.35, .88), (-.5, .35, 4.35, .8), (.6, .35, 4.4, .78),
               (.1, .45, 4.85, .7), (-1.55, .1, 2.8, .6), (1.6, .05, 2.95, .62), (-.2, -.2, 3.1, .55)]

def tree_grown():
    return trunk(3.9, .3, .13, GROWN_BOUGHS, GROWN_CROWN)

def tree_full():
    x, y = TREE
    p = tree_grown()
    for i, (dx, dy, dz, rr) in enumerate(GROWN_CROWN[:7]):  # puffs so the full crown reads as layered felt
        for k in range(3):
            a = k * 2.1 + i; p.append(ball('leaf puff', (x + dx + rr * .8 * math.cos(a), y + dy - .3, dz + rr * .55 * math.sin(a)), (rr * .38, rr * .32, rr * .34), ['Grass light', 'Leaf', 'Grass felt'][(i + k) % 3], 12, 8))
    return p

# ── The treehouse, piece by piece (stage 4: 12 pieces).
dx, dy, dz = DECK
def treehouse_parts():
    names = []
    names.append(part('th_brackets', [rod('bracket', (trunk_x(1.3), TREE[1] - .05, 1.35), (dx + s * DW * .38, dy + .2, dz - .06), .06, 'Walnut') for s in (-1, 1)]
                      + [rod('bracket', (trunk_x(1.5), TREE[1] + .1, 1.5), (dx, dy + DD * .45, dz - .06), .05, 'Walnut')]))
    deck = [rbox('deck', (dx, dy, dz - .05), (DW, DD, .1), 'Plank', .2)]
    for k in range(int(DW / .16)): deck.append(rbox('deck seam', (dx - DW / 2 + .16 * (k + .5), dy, dz + .002), (.008, DD - .04, .004), 'Plank dark', .2))
    names.append(part('th_deck', deck))
    lx, ly = dx - DW / 2 + .25, dy - DD / 2 - .05
    ladder = [rod('ladder rail', (lx + s * .16, ly - .45, 0), (lx + s * .16, ly - .02, dz + .45), .025, 'Walnut') for s in (-1, 1)]
    for k in range(9):
        z = .2 + k * (dz / 9); t = z / (dz + .45); ladder.append(rod('rung', (lx - .16, ly - .45 + .43 * t, z), (lx + .16, ly - .45 + .43 * t, z), .018, 'Plank'))
    names.append(part('th_ladder', ladder))
    rail = []
    for (ax, ay), (bx, by) in [((dx - DW / 2 + .55, dy - DD / 2), (dx + DW / 2, dy - DD / 2)), ((dx + DW / 2, dy - DD / 2), (dx + DW / 2, dy + DD / 2))]:
        n = int(math.hypot(bx - ax, by - ay) / .22) + 1
        for k in range(n + 1): t = k / n; rail.append(rod('baluster', (ax + (bx - ax) * t, ay + (by - ay) * t, dz), (ax + (bx - ax) * t, ay + (by - ay) * t, dz + .42), .014, 'Walnut'))
        rail.append(rod('handrail', (ax, ay, dz + .44), (bx, by, dz + .44), .025, 'Honey wood'))
    names.append(part('th_rail', rail))
    cx, cy = dx + .15, dy + .12  # the cabin sits at the back of the deck
    names.append(part('th_back', [rbox('back wall', (cx, cy + CD / 2 - .035, dz + CH / 2), (CW, .07, CH), 'Wall butter', .15),
                                  rbox('floor', (cx, cy, dz + .02), (CW, CD, .04), 'Plank dark', .2)]))
    walls = []
    for s in (-1, 1):
        walls.append(rbox('side wall', (cx + s * (CW / 2 - .035), cy, dz + CH / 2), (.07, CD, CH), 'Wall butter', .15))
        walls.append(rbox('corner post', (cx + s * CW / 2, cy - CD / 2 + .04, dz + CH / 2), (.1, .1, CH + .04), 'Trim', .4))
    names.append(part('th_walls', walls))
    front = [rbox('front wall l', (cx - CW / 2 + .22, cy - CD / 2 + .035, dz + CH / 2), (.44, .07, CH), 'Wall butter', .15),
             rbox('front wall r', (cx + CW / 2 - .3, cy - CD / 2 + .035, dz + CH / 2), (.6, .07, CH), 'Wall butter', .15),
             rbox('lintel', (cx - .03, cy - CD / 2 + .035, dz + CH - .12), (.5, .07, .24), 'Wall butter', .15)]
    door = rbox('door', (cx - .03, cy - CD / 2 + .02, dz + .45), (.4, .05, .82), 'Door green', .5)
    front += [door, ball('door knob', (cx + .1, cy - CD / 2 - .02, dz + .45), (.025, .025, .025), 'Brass', 8, 5)]
    names.append(part('th_front', front))
    names.append(part('th_window', [cyl('window', (cx + CW / 2 - .3, cy - CD / 2 - .005, dz + CH * .62), .17, .04, 'Glass', 20, (math.pi / 2, 0, 0)),
                                    cyl('window rim', (cx + CW / 2 - .3, cy - CD / 2 - .02, dz + CH * .62), .2, .025, 'Trim', 20, (math.pi / 2, 0, 0)),
                                    rbox('window cross', (cx + CW / 2 - .3, cy - CD / 2 - .03, dz + CH * .62), (.34, .015, .02), 'Trim', .2)]))
    half = CW / 2 + .22; pitch = math.radians(28); rise = half * math.tan(pitch); L = half / math.cos(pitch) + .03
    for s, name in ((-1, 'th_roof_l'), (1, 'th_roof_r')):
        panel = rbox('roof', (0, 0, 0), (L, CD + .4, .09), 'Roof terracotta', .3); panel.rotation_euler.y = s * pitch
        panel.location = (cx + s * half / 2, cy, dz + CH + rise / 2 + .06)
        extra = []
        for k in range(3):
            t = (k + .5) / 3; course = rbox('shingle', (0, 0, 0), (.03, CD + .42, .035), 'Shingle', .5); course.rotation_euler.y = s * pitch
            course.location = (cx + s * half * t, cy, dz + CH + rise * (1 - t) + .11); extra.append(course)
        if s == 1:
            extra.append(rbox('ridge', (cx, cy, dz + CH + rise + .1), (.1, CD + .44, .1), 'Walnut', .4))
            me = bpy.data.meshes.new('gable'); bm = bmesh.new()
            for yy, flip in ((cy - CD / 2, True), (cy + CD / 2, False)):
                vs = [bm.verts.new((cx - CW / 2, yy, dz + CH)), bm.verts.new((cx + CW / 2, yy, dz + CH)), bm.verts.new((cx, yy, dz + CH + rise * (CW / 2) / half))]
                bm.faces.new(vs[::-1] if flip else vs)
            bm.to_mesh(me); bm.free(); g = bpy.data.objects.new('gable', me); bpy.context.collection.objects.link(g); extra.append(finish(g, 'gable', H.M['Wall butter']))
        names.append(part(name, [panel] + extra))
    box = [rbox('flower box', (cx + CW / 2 - .3, cy - CD / 2 - .1, dz + CH * .42), (.46, .12, .1), 'Honey wood', .3)]
    for k in range(4): box.append(ball('box flower', (cx + CW / 2 - .48 + k * .12, cy - CD / 2 - .1, dz + CH * .42 + .08), (.04, .04, .035), ['Petal red', 'Petal yellow', 'Petal white', 'Petal pink'][k], 8, 5))
    names.append(part('th_flowers', box))
    names.append(part('th_lantern', [rod('lantern arm', (cx - CW / 2 - .02, cy - CD / 2 + .05, dz + CH - .05), (cx - CW / 2 - .22, cy - CD / 2 + .05, dz + CH - .05), .012, 'Iron'),
                                     cyl('lantern', (cx - CW / 2 - .22, cy - CD / 2 + .05, dz + CH - .2), .06, .14, 'Lamp glow', 12),
                                     cone('lantern cap', (cx - CW / 2 - .22, cy - CD / 2 + .05, dz + CH - .1), .08, .02, .06, 'Iron', 12)]))
    return names, (cx, cy)

# ── Extras (stage 5) and grand extras (stage 6).
def extras(cabin):
    cx, cy = cabin; out = []
    bx, by = trunk_x(1.75) + 1.35 * math.cos(-.15) * .75, TREE[1] + .1
    out.append(slot(part('swing', [rod('swing rope', (bx + s * .2, by, 2.05), (bx + s * .2, by - .1, .55), .01, 'Honey wood') for s in (-1, 1)] + [rbox('swing seat', (bx, by - .1, .52), (.52, .2, .05), 'Plank', .3)])))
    out.append(kit('birdhouse', trunk_x(1.1) - .05, TREE[1] - .3, 1.05, -10, .9))
    flags = []
    a, b = Vector((cx + CW / 2 + .2, cy - CD / 2, dz + CH + .15)), Vector((trunk_x(2.7) - 1.0, TREE[1] - .3, 2.75))
    for k in range(9):
        t = (k + .5) / 9; p = a.lerp(b, t) - Vector((0, 0, .18 * math.sin(math.pi * t)))
        f = cone('flag', (p.x, p.y, p.z - .07), .06, 0, .12, ['Petal red', 'Petal yellow', 'Teal felt', 'Petal pink'][k % 4], 3); f.rotation_euler = (math.pi, 0, .3); flags.append(f)
    flags.append(curve('bunting line', [a, a.lerp(b, .5) - Vector((0, 0, .18)), b], .006, 'Paper', 6))
    out.append(slot(part('bunting', flags)))
    out.append(kit('telescope', dx + DW / 2 - .25, dy - DD / 2 + .3, dz, 35, .9))
    chime = [rod('chime bar', (dx + DW / 2 - .05, dy - DD / 2 + .05, dz + .44), (dx + DW / 2 - .05, dy - DD / 2 + .05, dz + .28), .006, 'Iron')]
    for k in range(4): chime.append(cyl('chime', (dx + DW / 2 - .05 + (k - 1.5) * .035, dy - DD / 2 + .05, dz + .2 - k * .02), .008, .12 + k * .02, 'Brass', 8))
    out.append(slot(part('windchime', chime)))
    hx0, hx1 = trunk_x(.9) - .3, -1.9
    ham = [rod('hammock post', (hx1, TREE[1] - .2, 0), (hx1, TREE[1] - .2, 1.0), .04, 'Walnut')]
    pts = [(hx0 + (hx1 - hx0) * t, TREE[1] - .2, .85 - .35 * math.sin(math.pi * t)) for t in [k / 8 for k in range(9)]]
    ham.append(curve('hammock', pts, .09, 'Teal felt', 8))
    out.append(slot(part('hammock', ham)))
    out.append(kit('flower_c', dx + DW / 2 + .1, dy - DD / 2 - .6, 0, 0, 1))
    out.append(slot(part('roof_flag', [rod('flag pole', (cx, cy, dz + CH + .55), (cx, cy, dz + CH + 1.05), .012, 'Walnut'),
                                       cone('pennant', (cx + .1, cy, dz + CH + .95), .09, 0, .2, 'Petal yellow', 3)])))
    rl = [rod('rope ladder side', (dx + DW / 2 - .1 + s * .12, dy + DD / 2 - .1, dz), (dx + DW / 2 - .1 + s * .12, dy + DD / 2 - .05, .3), .01, 'Honey wood') for s in (-1, 1)]
    for k in range(6): z = .45 + k * .27; rl.append(rod('rope rung', (dx + DW / 2 - .22, dy + DD / 2 - .07, z), (dx + DW / 2 + .02, dy + DD / 2 - .07, z), .012, 'Plank'))
    out.append(slot(part('rope_ladder', rl)))
    kite = [cone('kite', (2.4, -.6, 4.3), .3, 0, .06, 'Petal red', 4), curve('kite string', [(2.4, -.6, 4.2), (2.0, -.2, 3.2), (dx + DW / 2, dy - DD / 2, dz + .45)], .004, 'Paper', 6)]
    for k in range(3): kite.append(ball('kite bow', (2.4 - .05 * k, -.6, 4.05 - .16 * k), (.035, .02, .02), 'Petal yellow', 6, 4))
    out.append(slot(part('kite', kite)))
    out.append(kit('pumpkin', -1.1, -1.2, 0, 20, 1))
    out.append(kit('plush_carrot', dx - .4, dy - .2, dz, 30, 1))
    return out

def grand(cabin):
    cx, cy = cabin; out = []; nx, ny = trunk_x(NEST_Z), TREE[1]
    out.append(slot(part('nest_deck', [cyl('nest floor', (nx, ny, NEST_Z), .75, .1, 'Plank', 24), rod('mast', (trunk_x(3.6), ny, 3.6), (nx, ny, NEST_Z + .05), .09, 'Bark')])))
    rail = [rod('nest post', (nx + .68 * math.cos(k * math.pi / 6), ny + .68 * math.sin(k * math.pi / 6), NEST_Z), (nx + .68 * math.cos(k * math.pi / 6), ny + .68 * math.sin(k * math.pi / 6), NEST_Z + .4), .02, 'Walnut') for k in range(12)]
    rail.append(curve('nest rail', [(nx + .68 * math.cos(k * math.pi / 12), ny + .68 * math.sin(k * math.pi / 12), NEST_Z + .42) for k in range(25)], .025, 'Honey wood', 3))
    out.append(slot(part('nest_rail', rail)))
    roof = [rod('nest roof post', (nx + .6 * math.cos(a), ny + .6 * math.sin(a), NEST_Z), (nx + .6 * math.cos(a), ny + .6 * math.sin(a), NEST_Z + .9), .025, 'Walnut') for a in (.4, 2.0, 3.5, 5.1)]
    roof.append(cone('nest roof', (nx, ny, NEST_Z + 1.15), .92, .04, .5, 'Roof teal', 16))
    out.append(slot(part('nest_roof', roof)))
    lad = [rod('nest ladder', (cx - .35 + s * .12, cy - .1, dz + CH + .3), (nx + .45 + s * .12, ny - .2, NEST_Z), .02, 'Walnut') for s in (-1, 1)]
    for k in range(5): t = (k + .5) / 5; a, b = Vector((cx - .35, cy - .1, dz + CH + .3)), Vector((nx + .45, ny - .2, NEST_Z)); p = a.lerp(b, t); lad.append(rod('rung', (p.x - .12, p.y, p.z), (p.x + .12, p.y, p.z), .015, 'Plank'))
    out.append(slot(part('nest_ladder', lad)))
    sx, sy = dx + DW / 2, dy + .1
    pts = [(sx + .9 * t, sy - .5 * t, dz - (dz - .15) * (t ** 1.3)) for t in [k / 10 for k in range(11)]]
    slide = [curve('slide', pts, .14, 'Petal yellow', 10)]
    slide += [curve('slide lip', [(x, y + s * .13, z + .05) for x, y, z in pts], .025, 'Honey wood', 10) for s in (-1, 1)]
    out.append(slot(part('slide', slide)))
    zx, zy = -2.6, -1.3
    out.append(slot(part('zip_post', [rod('zip post', (zx, zy, 0), (zx, zy, 1.6), .05, 'Walnut'), rod('zip brace', (zx, zy, 1.2), (zx + .35, zy + .2, 0), .03, 'Walnut')])))
    zp = [(nx - .5 + (zx - nx + .5) * t, ny + (zy - ny) * t, NEST_Z + .3 + (1.55 - NEST_Z - .3) * t - .25 * math.sin(math.pi * t)) for t in [k / 12 for k in range(13)]]
    zipl = [curve('zipline', zp, .008, 'Iron', 12), rod('zip hanger', zp[6], (zp[6][0], zp[6][1], zp[6][2] - .35), .01, 'Honey wood'), rbox('zip seat', (zp[6][0], zp[6][1], zp[6][2] - .38), (.24, .12, .04), 'Petal red', .4)]
    out.append(slot(part('zipline', zipl)))
    out.append(slot(part('bell', [rod('bell arm', (nx + .6, ny - .3, NEST_Z + .85), (nx + .75, ny - .35, NEST_Z + .85), .012, 'Iron'), cone('bell', (nx + .75, ny - .35, NEST_Z + .72), .07, .03, .12, 'Brass', 14)])))
    out.append(slot(part('balloon', [ball('balloon', (-1.6, .2, 5.4), (.42, .42, .5), 'Petal red', 18, 12), cone('balloon basket', (-1.6, .2, 4.72), .12, .15, .14, 'Honey wood', 10),
                                     curve('balloon rope', [(-1.6, .2, 4.65), (-1.1, .3, 4.2), (nx - .6, ny, NEST_Z + .4)], .005, 'Paper', 6)])))
    out.append(slot(part('chimney', [rbox('chimney', (cx + CW / 2 - .35, cy + .15, dz + CH + .45), (.18, .18, .5), 'Stone', .3)] +
                                    [ball('smoke', (cx + CW / 2 - .35 + .05 * k, cy + .15, dz + CH + .8 + .22 * k), (.08 + .03 * k, .08 + .03 * k, .07 + .02 * k), 'Plaster', 10, 6) for k in range(3)])))
    lights = []
    for (z0, a, length, r) in GROWN_BOUGHS[:4]:
        for k in range(6):
            t = (k + .5) / 6; x0 = trunk_x(z0) + length * t * math.cos(a); lights.append(ball('string light', (x0, TREE[1] - .05, z0 + length * .35 * t - .04), (.025, .025, .03), 'Lamp glow', 6, 4))
    out.append(slot(part('string_lights', lights)))
    out.append(kit('welcome_sign', .6, -2.2, 0, -10, 1))
    return out

# ── Build everything.
part('plot', plot(), 60000)
terrain = [slot(part('tree_seed', tree_seed())), slot(part('tree_sapling', tree_sapling())), slot(part('tree_young', tree_young())),
           slot(part('tree_grown', tree_grown(), 60000)), slot(part('tree_full', tree_full(), 90000))]
th, cabin = treehouse_parts()
stages = [
    {'threshold': 0, 'room': 'seed', 'structure': [], 'items': [kit('watering_can', -.55, .05, 0, 30), kit('stepping_stone', -.2, -.6), kit('welcome_sign', .65, -.25, 0, -15, .8)]},
    {'threshold': 30, 'room': 'sapling', 'structure': [], 'items': [kit('flower_a', .5, .95), kit('flower_b', -.55, 1.0), kit('fern', -.9, .5)]},
    {'threshold': 60, 'room': 'young tree', 'structure': [], 'items': [kit('stepping_stone', .15, -1.2, 0, 40), kit('bush', 1.3, 1.3), kit('sunflower', -1.2, 1.25)]},
    {'threshold': 90, 'room': 'tree', 'structure': [], 'items': [kit('bench', -1.35, -.35, 0, 25), kit('lantern_post', 1.35, -.6), kit('mailbox', -.75, -1.55, 0, 10)]},
    {'threshold': 120, 'room': 'treehouse', 'structure': [], 'items': [slot(n) for n in th]},
    {'threshold': 240, 'room': 'extras', 'structure': [], 'items': extras(cabin), 'light': point((cabin[0], cabin[1], dz + .7))},
    {'threshold': 360, 'room': 'grand extras', 'structure': [], 'items': grand(cabin)},
    {'threshold': 480, 'room': 'stars', 'structure': [], 'items': []},
]
assert len(stages[4]['items']) == 12 and len(stages[5]['items']) == 12 and len(stages[6]['items']) == 12, [len(s['items']) for s in stages]
bulbs = []
for (z0, a, length, r) in GROWN_BOUGHS:  # lanterns for returns, hung under the boughs
    for t in (.55, .85):
        x0 = trunk_x(z0) + length * t * math.cos(a); z = z0 + length * .35 * t - .18
        bulbs.append(slot('bulb', M(x0, TREE[1] - .1, z), home=None, stage=4))
stars = [point((rng.uniform(-5.5, 5.5), rng.uniform(1.5, 5), rng.uniform(4.2, 7.6))) for _ in range(600)]  # a band above the crown, in view
direction = Vector((-.36, -1.0, .40)).normalized()
cams = []
for threshold, target, distance in [(0, (-.35, .2, .45), 5.4), (30, (-.3, .3, .65), 5.8), (60, (-.1, .4, 1.15), 7.0), (90, (.05, .35, 2.25), 9.8), (120, (.25, .25, 2.25), 10.6), (360, (.2, .25, 3.45), 15.2)]:
    t = Vector(target); cams.append({'threshold': threshold, 'target': point(t), 'from': point(t + direction * distance)})
moku = {  # [x, y, z, turn°] in RealityKit space
    'door': point((-1.05, -.75, 0)) + [20], 'early': point((-1.05, -.75, 0)) + [20],
    'focus': point((-.8, -.35, 0)) + [-15], 'break': point((-1.2, -.95, 0)) + [25],
    'away': point((-.6, -.15, 0)) + [10], 'drift': point((-.1, -2.1, 0)) + [0],
}
layout = {'schemaVersion': 1, 'thresholds': THRESHOLDS, 'rooms': STAGES, 'pointsPerItem': 10,
          'note': 'Today\'s tree: points are focused minutes today; one item per 10 minutes; stars after 8 hours.',
          'homes': {'daytree': {'base': [slot('plot')], 'terrain': terrain, 'stages': stages, 'moku': moku, 'garland': [], 'bulbs': bulbs, 'stars': stars, 'starScale': 4.0, 'cameras': cams}}}
(OUT / 'layout.json').write_text(json.dumps(layout) + '\n')
(OUT / 'manifest.json').write_text(json.dumps({'parts': H.MANIFEST}, indent=1) + '\n')
print('TREE_KIT', len(H.MANIFEST), 'parts', sum(p['triangles'] for p in H.MANIFEST), 'triangles')
