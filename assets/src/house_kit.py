"""Today's house: one cute cottage a day, built with focused minutes (Charles, 2026-09-30).

The house from 2026-09-24 (world_v2.py: the round plot, the wooden cabin with a pale teal roof, the round door and
the plan board out front), with far more detail, and built again every day. Every 10 focused minutes adds the next
piece; 4 hours finishes the house:
  0-40 min    the ground: stakes and string, stone footings, joists, the floor
  40-80 min   the frame: posts, top plates, rafters, the ridge (with a topping-out flag)
  80-140 min  the walls: back, left, right, front, the round door, the windows
  140-180 min the roof: two slopes of felt scallop shingles, the trim, the chimney
  180-240 min the home: the porch, flower boxes, the porch lamp, the fence, the garden, and the finale
              (smoke from the chimney, lit windows, a wreath on the door)
The site changes with it (terrain): lumber, a toolbox and Moku's little tent at first, scaffolding while the walls
and roof go up, a tidy yard with a bench and a young tree once the house is done. The layout uses the home's schema
(HomeLayout in HomeWorld.swift), so the app's renderer draws it as it draws the home.

Run: Blender --background --factory-startup --python-exit-code 1 --python assets/src/house_kit.py"""
import sys, math, json, random
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ROOT, reset, finish
import home_parts as H
from home_parts import rbox, ball, cyl, cone, rod, curve
import bpy, bmesh
from mathutils import Vector, Matrix

OUT = ROOT / 'world/dayhouse'; OUT.mkdir(parents=True, exist_ok=True)
reset(); H.materials(ROOT); rng = random.Random(24)

THRESHOLDS = [0, 40, 80, 140, 180, 240]
STAGES = ['ground', 'frame', 'walls', 'roof', 'home', 'complete']
HX, HY = 0.25, 0.45           # the house's centre on the plot; the plot's front is -y
W, D = 2.2, 1.7               # its footprint
FZ = 0.24                     # the floor's top, on stone footings
WH = 1.25                     # wall height above the floor
TZ = FZ + WH                  # the eaves
PITCH = math.radians(33)
OVER = 0.22                   # roof overhang past the walls
X0, X1, Y0, Y1 = HX - W / 2, HX + W / 2, HY - D / 2, HY + D / 2
HALF = W / 2 + OVER
RISE = (W / 2) * math.tan(PITCH)       # wall top to ridge
RIDGE = TZ + RISE
DOOR_W, DOOR_H = 0.56, 0.98
WIN_R = 0.17
WIN_Z = FZ + 0.72
WINDOWS = [(HX - 0.72, Y0), (HX + 0.72, Y0)]   # the two front windows
LAMP = (HX + DOOR_W / 2 + 0.2, Y0 - 0.06, FZ + DOOR_H + 0.1)

C = Matrix.Rotation(-math.pi / 2, 4, 'X')
def slot(asset, m=None, home='dayhouse', **extra):
    m = m or Matrix.Identity(4)
    t, q, s = (C @ m @ C.inverted()).decompose()
    out = {'asset': asset, 't': [round(v, 4) for v in t], 'q': [round(q.x, 5), round(q.y, 5), round(q.z, 5), round(q.w, 5)], 's': [round(v, 4) for v in s]}
    if home: out['home'] = home
    out.update(extra); return out
def M(x, y, z=0, rz=0, s=1): return Matrix.Translation((x, y, z)) @ Matrix.Rotation(math.radians(rz), 4, 'Z') @ Matrix.Diagonal((s, s, s, 1))
def point(v): return [round(v[0], 4), round(v[2], 4), round(-v[1], 4)]
def part(name, objs, limit=30000): H.save(OUT, name, objs, limit); return name

def gable(name, ya, yb, material):
    """The triangle above a front or back wall: a prism from face ya to face yb, under the ridge."""
    me = bpy.data.meshes.new(name); bm = bmesh.new()
    f = [bm.verts.new(p) for p in ((X0, ya, TZ), (X1, ya, TZ), (HX, ya, RIDGE))]
    b = [bm.verts.new(p) for p in ((X0, yb, TZ), (X1, yb, TZ), (HX, yb, RIDGE))]
    bm.faces.new(f); bm.faces.new(b[::-1])
    for i in range(3):
        j = (i + 1) % 3; bm.faces.new((f[j], f[i], b[i], b[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free(); o = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(o)
    return finish(o, name, H.M[material])

def boards(x0, x1, y, z0, z1, axis='x', seam=.18):
    """Vertical board seams across a wall face (thin darker strips), so a wall reads as planks."""
    out = []
    length = (x1 - x0); n = max(2, int(length / seam))
    for k in range(1, n):
        c = x0 + length * k / n
        loc = (c, y, (z0 + z1) / 2) if axis == 'x' else (y, c, (z0 + z1) / 2)
        size = (.012, .012, z1 - z0 - .04)
        out.append(rbox('board seam', loc, size, 'Honey wood', .2))
    return out

# ── The plot: a round felt lawn over a bank of earth, a path to the gate, wild flowers kept off the build.
def plot(radius=3.3):
    p = [ball('bank', (0, 0, -.64), (radius, radius * .85, .6), 'Earth side', 56, 20)]
    p.append(ball('lawn', (0, 0, -.03), (radius + .06, radius * .85 + .06, .12), 'Grass felt', 56, 14))
    for i in range(28):
        a = i * 2 * math.pi / 28; p.append(ball('scallop', ((radius - .04) * math.cos(a), (radius * .85 - .04) * math.sin(a), -.05), (.26, .26, .1), 'Grass felt', 10, 6))
    for i in range(12):
        a = i * 2 * math.pi / 12 + .3; p.append(ball('bank stone', (radius * .96 * math.cos(a), radius * .82 * math.sin(a), -.32 - .15 * (i % 3)), (.18, .15, .13), 'Stone', 10, 6))
    for i in range(80):
        a = rng.uniform(0, 2 * math.pi); rr = radius * math.sqrt(rng.uniform(.1, .93)); x, y = rr * math.cos(a), rr * .85 * math.sin(a)
        if X0 - .6 < x < X1 + .6 and Y0 - 1.3 < y < Y1 + .4: continue      # the house, its porch and yard
        if abs(x - HX) < .5 and y < Y0: continue                             # the path
        if -2.45 < x < -1.2 and -1.4 < y < -.4: continue                     # the plan board
        if i % 9 == 0: p += [cyl('mushroom stem', (x, y, .1), .014, .07, 'Paper', 8), ball('mushroom cap', (x, y, .15), (.05, .045, .022), 'Petal red', 10, 6)]
        elif i % 3 == 0: p.append(ball('wild flower', (x, y, .12), (.028, .028, .02), ['Petal white', 'Petal yellow', 'Petal blue'][i % 3], 8, 5))
        else: p.append(cone('tuft', (x, y, .09), .04, 0, .1, 'Grass light' if i % 2 else 'Grass deep', 5))
    return p

# ── The plan board: a wooden easel with the house drawn on it in ink (the plan being built).
def plan_board(x=-1.8, y=-.9, turn=-18):
    p = [rbox('board frame', (0, 0, .98), (1.0, .06, .74), 'Walnut', .2), rbox('paper', (0, -.035, .98), (.88, .012, .62), 'Paper', .1)]
    for sx in (-.36, .36): p.append(rod('easel leg', (sx, .06, 0), (sx * .9, 0, 1.3), .025, 'Walnut'))
    p.append(rod('easel back leg', (0, .45, 0), (0, .05, 1.25), .022, 'Walnut'))
    p.append(rbox('ledge', (0, -.06, .6), (.95, .1, .03), 'Walnut', .2))
    p.append(rod('pencil', (.18, -.07, .63), (.36, -.07, .64), .012, 'Mustard felt'))
    ink = lambda a, b, r=.008: rod('ink line', (a[0], -.043, a[1]), (b[0], -.043, b[1]), r, 'Ink', 6)
    bx0, bx1, bz0, bz1, peak = -.2, .2, .76, 1.02, 1.2
    p += [ink((bx0, bz0), (bx1, bz0)), ink((bx1, bz0), (bx1, bz1)), ink((bx1, bz1), (bx0, bz1)), ink((bx0, bz1), (bx0, bz0)),
          ink((bx0 - .05, bz1), (0, peak)), ink((0, peak), (bx1 + .05, bz1)),
          ink((-.04, bz0), (-.04, .88)), ink((.04, bz0), (.04, .88)), ink((-.04, .88), (.04, .88))]
    for k in range(3): p.append(ink((.26, 1.18 - k * .06), (.4, 1.18 - k * .06), .006))       # notes in the margin
    o = H.join('plan board', p); o.matrix_world = M(x, y, 0, turn) @ o.matrix_world
    return [o]

def lumber(x, y, layers=3, turn=10):
    p = []
    for L in range(layers):
        for k in range(3):
            if L % 2 == 0: p.append(rbox('plank', (0, (k - 1) * .14, .03 + L * .06), (1.1, .12, .05), 'Plank', .25))
            else: p.append(rbox('plank', ((k - 1) * .3, 0, .03 + L * .06), (.12, .5, .05), 'Plank dark', .25))
    o = H.join('lumber', p); o.matrix_world = M(x, y, 0, turn) @ o.matrix_world; return [o]

def toolbox(x, y, turn=-20):
    p = [rbox('toolbox', (0, 0, .09), (.36, .18, .16), 'Rust felt', .3), rod('handle', (-.1, 0, .2), (.1, 0, .2), .014, 'Iron'),
         rod('handle post', (-.1, 0, .17), (-.1, 0, .21), .012, 'Iron'), rod('handle post', (.1, 0, .17), (.1, 0, .21), .012, 'Iron'),
         rod('hammer handle', (.26, -.08, .02), (.46, .02, .02), .016, 'Walnut'), rbox('hammer head', (.47, .02, .025), (.05, .12, .05), 'Iron', .3)]
    o = H.join('toolbox', p); o.matrix_world = M(x, y, 0, turn) @ o.matrix_world; return [o]

def sawhorse(x, y, turn=30):
    p = [rbox('beam', (0, 0, .42), (.8, .1, .08), 'Walnut', .2)]
    for sx in (-.3, .3):
        for sy in (-1, 1): p.append(rod('leg', (sx, sy * .16, 0), (sx, 0, .4), .025, 'Walnut'))
    p.append(rbox('cut plank', (.05, 0, .49), (.7, .14, .04), 'Plank', .25))
    o = H.join('sawhorse', p); o.matrix_world = M(x, y, 0, turn) @ o.matrix_world; return [o]

def tent(x=-2.05, y=.75, turn=25):
    """Moku's little tent: where it camps until the house is done."""
    p = []
    for s in (-1, 1):
        side = rbox('tent side', (s * .2, 0, .27), (.5, .72, .03), 'Cream felt', .3); side.rotation_euler.y = s * math.radians(42); p.append(side)
    p.append(rbox('tent floor', (0, 0, .015), (.66, .76, .03), 'Teal felt', .3))
    p.append(rod('tent pole', (0, -.38, 0), (0, -.38, .6), .012, 'Walnut'))
    p.append(cone('pennant', (.06, -.38, .56), .05, 0, .12, 'Petal red', 3, (0, math.pi / 2, 0)))
    o = H.join('tent', p); o.matrix_world = M(x, y, 0, turn) @ o.matrix_world; return [o]

def scaffold(side):
    x = (X1 + .38) if side > 0 else (X0 - .38)
    p = []
    for y in (Y0 + .05, Y1 - .05):
        p.append(rod('scaffold upright', (x - .14, y, 0), (x - .14, y, 1.6), .025, 'Walnut'))
        p.append(rod('scaffold upright', (x + .14, y, 0), (x + .14, y, 1.6), .025, 'Walnut'))
    for z in (.55, 1.15):
        p.append(rbox('scaffold plank', (x, (Y0 + Y1) / 2, z), (.34, D, .05), 'Plank', .25))
    p.append(rod('brace', (x - .14, Y0 + .05, .1), (x - .14, Y1 - .05, 1.1), .018, 'Walnut'))
    return p

def ladder_to_roof():
    lx = X0 - .55; p = []
    for s in (-1, 1): p.append(rod('ladder rail', (lx - .25, HY + s * .18, 0), (X0 - .08, HY + s * .18, TZ + .1), .024, 'Walnut'))
    for k in range(8):
        t = (k + .6) / 9; x = lx - .25 + (X0 - .08 - lx + .25) * t; z = (TZ + .1) * t
        p.append(rod('rung', (x, HY - .18, z), (x, HY + .18, z), .016, 'Plank'))
    return p

def bench(x, y, turn):
    p = [rbox('seat', (0, 0, .24), (.8, .26, .05), 'Honey wood', .3), rbox('back', (0, .12, .42), (.8, .04, .2), 'Honey wood', .3)]
    for sx in (-.32, .32):
        for sy in (-.09, .09): p.append(rod('bench leg', (sx, sy, 0), (sx, sy, .23), .022, 'Walnut'))
    o = H.join('bench', p); o.matrix_world = M(x, y, 0, turn) @ o.matrix_world; return [o]

def young_tree(x, y, s=1.0):
    p = [rod('trunk', (x, y, 0), (x + .03, y, 1.0 * s), .06 * s, 'Bark')]
    for (dx, dy, dz, r, m) in [(-.2, 0, 1.05, .33, 'Leaf'), (.22, .04, 1.1, .34, 'Leaf dark'), (0, -.1, 1.35, .36, 'Grass light'), (.05, .15, 1.25, .3, 'Leaf')]:
        p.append(ball('crown', (x + dx * s, y + dy * s, dz * s), (r * s, r * .9 * s, r * .92 * s), m, 16, 10))
    return p

# ── The house, piece by piece (24 pieces, 10 focused minutes each).
def house():
    names = []
    # The ground (0-40 min).
    corners = [(X0, Y0), (X1, Y0), (X1, Y1), (X0, Y1)]
    stakes = []
    for (x, y) in corners:
        stakes += [rod('stake', (x, y, 0), (x, y, .38), .022, 'Walnut'), cone('stake flag', (x + .05, y, .34), .045, 0, .1, 'Petal red', 3, (0, math.pi / 2, 0))]
    for i in range(4):
        (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
        stakes.append(rod('string', (ax, ay, .28), (bx, by, .28), .005, 'Paper', 6))
    names.append(part('hs_stakes', stakes))
    footings = []
    for i in range(3):
        for j in range(3):
            x, y = X0 + .12 + (W - .24) * i / 2, Y0 + .12 + (D - .24) * j / 2
            footings.append(ball('footing', (x, y, .07), (.2, .17, .12), 'Stone', 14, 8))
            footings.append(ball('footing moss', (x + .06, y - .05, .15), (.07, .06, .03), 'Grass deep', 8, 5))
    names.append(part('hs_footings', footings))
    joists = [rbox('rim beam', (X0 + .05, HY, .15), (.1, D, .1), 'Walnut', .2), rbox('rim beam', (X1 - .05, HY, .15), (.1, D, .1), 'Walnut', .2)]
    for k in range(5): joists.append(rbox('joist', (HX, Y0 + .08 + (D - .16) * k / 4, .15), (W, .09, .1), 'Walnut', .2))
    names.append(part('hs_joists', joists))
    floor = [rbox('floor', (HX, HY, FZ - .03), (W + .08, D + .08, .06), 'Plank', .25)]
    for k in range(1, 11): floor.append(rbox('floor seam', (X0 + W * k / 11, HY, FZ + .001), (.01, D + .06, .004), 'Plank dark', .2))
    names.append(part('hs_floor', floor))
    # The frame (40-80 min).
    posts = [rbox('corner post', (x, y, FZ + WH / 2), (.1, .1, WH), 'Walnut', .2) for (x, y) in corners]
    for sx in (-1, 1): posts.append(rbox('door post', (HX + sx * (DOOR_W / 2 + .05), Y0, FZ + DOOR_H / 2), (.08, .08, DOOR_H), 'Walnut', .2))
    names.append(part('hs_posts', posts))
    plates = [rbox('top plate', (HX, y, TZ - .05), (W + .1, .1, .1), 'Walnut', .2) for y in (Y0, Y1)]
    plates += [rbox('top plate', (x, HY, TZ - .05), (.1, D + .1, .1), 'Walnut', .2) for x in (X0, X1)]
    plates.append(rbox('lintel beam', (HX, Y0, FZ + DOOR_H + .04), (DOOR_W + .2, .09, .08), 'Walnut', .2))
    names.append(part('hs_plates', plates))
    rafters = []
    for k in range(4):
        y = Y0 + D * k / 3
        rafters += [rod('rafter', (X0 - OVER * .8, y, TZ - .06), (HX, y, RIDGE), .035, 'Walnut'), rod('rafter', (X1 + OVER * .8, y, TZ - .06), (HX, y, RIDGE), .035, 'Walnut')]
        rafters.append(rod('collar tie', (X0 + .35, y, TZ + .2), (X1 - .35, y, TZ + .2), .025, 'Walnut'))
    names.append(part('hs_rafters', rafters))
    ridge = [rbox('ridge beam', (HX, HY, RIDGE + .02), (.1, D + OVER * 2, .1), 'Walnut', .2)]
    # Topping out: a little pole with a pennant and a leafy sprig on the ridge.
    ridge += [rod('flag pole', (HX, Y0 + .1, RIDGE), (HX, Y0 + .1, RIDGE + .5), .014, 'Walnut'),
              cone('pennant', (HX + .12, Y0 + .1, RIDGE + .44), .09, 0, .24, 'Mustard felt', 3, (0, math.pi / 2, 0)),
              ball('sprig', (HX, Y0 + .1, RIDGE + .1), (.1, .08, .12), 'Leaf', 10, 6)]
    names.append(part('hs_ridge', ridge))
    # The walls (80-140 min): honey-wood planks with darker seams, white corner boards.
    t = .07
    back = [rbox('back wall', (HX, Y1 - t / 2, FZ + WH / 2), (W, t, WH), 'Wall butter', .12), gable('back gable', Y1 - t, Y1, 'Wall butter')]
    back += boards(X0, X1, Y1 + .002, FZ, TZ)
    names.append(part('hs_wall_back', back))
    for side, name in ((-1, 'hs_wall_left'), (1, 'hs_wall_right')):
        x = X0 + t / 2 if side < 0 else X1 - t / 2
        wall = [rbox('side wall', (x, HY, FZ + WH / 2), (t, D, WH), 'Wall butter', .12)]
        wall += boards(Y0, Y1, x + side * .038, FZ, TZ, axis='y')
        wall.append(rbox('corner board', (x + side * .02, Y0 + .02, FZ + WH / 2), (.1, .1, WH + .02), 'Trim', .3))
        wall.append(rbox('corner board', (x + side * .02, Y1 - .02, FZ + WH / 2), (.1, .1, WH + .02), 'Trim', .3))
        if side < 0:  # a small square window with shutters on the left wall
            wall += [rbox('side window', (x - .04, HY, WIN_Z), (.02, .34, .34), 'Glass', .2), rbox('side window frame', (x - .05, HY, WIN_Z), (.02, .4, .04), 'Trim', .3),
                     rbox('side window frame', (x - .05, HY, WIN_Z), (.02, .04, .4), 'Trim', .3),
                     rbox('shutter', (x - .05, HY - .27, WIN_Z), (.02, .16, .42), 'Wall teal', .3), rbox('shutter', (x - .05, HY + .27, WIN_Z), (.02, .16, .42), 'Wall teal', .3)]
        names.append(part(name, wall))
    left_w = (HX - DOOR_W / 2) - X0; right_w = X1 - (HX + DOOR_W / 2)
    front = [rbox('front wall', (X0 + left_w / 2, Y0 + t / 2, FZ + WH / 2), (left_w, t, WH), 'Wall butter', .12),
             rbox('front wall', (X1 - right_w / 2, Y0 + t / 2, FZ + WH / 2), (right_w, t, WH), 'Wall butter', .12),
             rbox('over door', (HX, Y0 + t / 2, FZ + DOOR_H + (WH - DOOR_H) / 2), (DOOR_W, t, WH - DOOR_H), 'Wall butter', .12),
             gable('front gable', Y0, Y0 + t, 'Wall butter')]
    front += boards(X0, HX - DOOR_W / 2, Y0 - .002, FZ, TZ) + boards(HX + DOOR_W / 2, X1, Y0 - .002, FZ, TZ)
    front.append(cyl('gable vent', (HX, Y0 - .01, TZ + RISE * .45), .1, .03, 'Walnut', 16, (math.pi / 2, 0, 0)))
    front.append(cyl('gable vent inner', (HX, Y0 - .02, TZ + RISE * .45), .065, .03, 'Ink', 16, (math.pi / 2, 0, 0)))
    names.append(part('hs_wall_front', front))
    # The round door: arched top, teal boards, a brass knob, hinges and a little round window.
    dz = FZ + (DOOR_H - DOOR_W / 2) / 2
    door = [rbox('door', (HX, Y0 - .01, dz), (DOOR_W - .04, .05, DOOR_H - DOOR_W / 2), 'Wall teal', .15),
            cyl('door arch', (HX, Y0 - .01, FZ + DOOR_H - DOOR_W / 2), (DOOR_W - .04) / 2, .05, 'Wall teal', 28, (math.pi / 2, 0, 0))]
    for k in (-1, 0, 1): door.append(rbox('door board', (HX + k * .13, Y0 - .038, dz + .08), (.008, .008, DOOR_H - .2), 'Roof teal', .2))
    door += [ball('door knob', (HX + .17, Y0 - .06, FZ + .48), (.03, .03, .03), 'Brass', 10, 6),
             rbox('hinge', (HX - .2, Y0 - .04, FZ + .25), (.12, .012, .03), 'Iron', .3), rbox('hinge', (HX - .2, Y0 - .04, FZ + .7), (.12, .012, .03), 'Iron', .3),
             cyl('door window', (HX, Y0 - .04, FZ + DOOR_H - .28), .09, .02, 'Glass', 20, (math.pi / 2, 0, 0)),
             cyl('door window rim', (HX, Y0 - .045, FZ + DOOR_H - .28), .11, .015, 'Brass', 20, (math.pi / 2, 0, 0)),
             rbox('door frame', (HX, Y0 - .02, FZ + DOOR_H + .02), (DOOR_W + .12, .04, .06), 'Trim', .3)]
    names.append(part('hs_door', door))
    windows = []
    for (x, y) in WINDOWS:
        ring = [(x + (WIN_R + .02) * math.cos(a * 2 * math.pi / 32), y - .035, WIN_Z + (WIN_R + .02) * math.sin(a * 2 * math.pi / 32)) for a in range(33)]
        windows += [cyl('window glass', (x, y - .01, WIN_Z), WIN_R, .03, 'Glass', 24, (math.pi / 2, 0, 0)),
                    curve('window rim', ring, .03, 'Trim'),
                    rbox('window cross', (x, y - .05, WIN_Z), (WIN_R * 2, .015, .025), 'Trim', .2),
                    rbox('window cross', (x, y - .05, WIN_Z), (.025, .015, WIN_R * 2), 'Trim', .2),
                    rbox('window sill', (x, y - .06, WIN_Z - WIN_R - .05), (WIN_R * 2 + .14, .1, .035), 'Trim', .3)]
    names.append(part('hs_windows', windows))
    # The roof (140-180 min): pale teal slopes of felt scallop shingles.
    L = HALF / math.cos(PITCH) + .04
    panel_z = TZ + (HALF * math.tan(PITCH)) / 2 - (OVER * math.tan(PITCH)) + .02   # a slope's centre height
    ridge_top = panel_z + (HALF / 2) * math.tan(PITCH)
    for s, name in ((-1, 'hs_roof_left'), (1, 'hs_roof_right')):
        panel = rbox('roof', (0, 0, 0), (L, D + OVER * 2, .08), 'Wall teal', .3); panel.rotation_euler.y = s * PITCH
        panel.location = (HX + s * HALF / 2, HY, panel_z)
        roof = [panel]
        rows = 5
        for r in range(rows):
            f = (r + .35) / rows                     # 0 at the eave, 1 at the ridge
            x = HX + s * HALF * (1 - f)
            z = panel_z - (HALF / 2) * math.tan(PITCH) + HALF * math.tan(PITCH) * f + .06
            n = 11
            for k in range(n):
                y = Y0 - OVER + (D + OVER * 2) * (k + .5 + (.5 if r % 2 else 0)) / n
                if y > Y1 + OVER - .05: continue
                sc = ball('shingle scallop', (x, y, z), (.15, .085, .035), 'Roof teal' if (r * 3 + k) % 9 == 0 else 'Wall teal', 10, 6)
                sc.rotation_euler.y = s * PITCH; roof.append(sc)
        names.append(part(name, roof))
    trim = [rbox('ridge cap', (HX, HY, ridge_top + .03), (.16, D + OVER * 2 + .04, .08), 'Trim', .4)]
    for yy in (Y0 - OVER - .01, Y1 + OVER + .01):
        for s in (-1, 1):
            trim.append(rod('fascia', (HX + s * (HALF + .02), yy, ridge_top - HALF * math.tan(PITCH) - .02), (HX, yy, ridge_top + .02), .03, 'Trim'))
    names.append(part('hs_trim', trim))
    cx, cy = HX + .6, Y1 - .45
    roof_z = ridge_top - (cx - HX) * math.tan(PITCH)
    chimney = [rbox('chimney', (cx, cy, roof_z + .2), (.28, .28, .8), 'Stone', .15), rbox('chimney cap', (cx, cy, roof_z + .62), (.36, .36, .07), 'Stone', .3)]
    for k in range(7): chimney.append(ball('chimney stone', (cx + rng.uniform(-.13, .13), cy - .145, roof_z + rng.uniform(-.1, .5)), (.05, .015, .035), 'Pebble', 8, 5))
    names.append(part('hs_chimney', chimney))
    # The home (180-240 min).
    py = Y0 - .3
    porch = [rbox('porch', (HX, py, FZ - .04), (1.2, .52, .07), 'Plank', .25),
             rbox('step', (HX, Y0 - .66, .15), (.9, .24, .08), 'Plank dark', .25), rbox('step', (HX, Y0 - .88, .06), (.9, .24, .08), 'Plank dark', .25)]
    for sx in (-1, 1): porch.append(rod('porch post', (HX + sx * .52, py - .2, FZ - .04), (HX + sx * .52, py - .2, FZ + DOOR_H + .22), .03, 'Trim'))
    awning = rbox('awning', (HX, Y0 - .3, FZ + DOOR_H + .3), (1.3, .66, .07), 'Wall teal', .3); awning.rotation_euler.x = math.radians(-24); porch.append(awning)
    for k in range(7): porch.append(ball('awning scallop', (HX - .6 + k * .2, Y0 - .62, FZ + DOOR_H + .16), (.1, .04, .07), 'Roof teal' if k % 2 else 'Wall teal', 10, 6))
    names.append(part('hs_porch', porch))
    boxes = []
    for (x, y) in WINDOWS:
        z = WIN_Z - WIN_R - .14
        boxes.append(rbox('flower box', (x, y - .1, z), (.48, .14, .12), 'Walnut', .3))
        for k in range(5):
            boxes.append(ball('box flower', (x - .18 + k * .09, y - .1, z + .09), (.045, .045, .04), ['Petal pink', 'Petal yellow', 'Petal white', 'Petal red', 'Petal blue'][k], 8, 5))
            boxes.append(ball('box leaf', (x - .14 + k * .09, y - .13, z + .06), (.035, .02, .025), 'Leaf', 8, 5))
    names.append(part('hs_flowerboxes', boxes))
    lx, ly, lz = LAMP
    names.append(part('hs_lamp', [rod('lamp arm', (lx - .1, ly + .05, lz + .12), (lx, ly - .02, lz + .12), .012, 'Iron'),
                                  cyl('lamp', (lx, ly - .02, lz), .06, .15, 'Lamp glow', 14), cone('lamp cap', (lx, ly - .02, lz + .1), .085, .015, .07, 'Iron', 14),
                                  cyl('lamp base', (lx, ly - .02, lz - .085), .05, .02, 'Iron', 14)]))
    fence = []
    rx, ry, fy = 2.0, 1.6, HY - .55
    pts = []
    for k in range(29):
        a = math.radians(192 + k * 156 / 28); x, y = HX + rx * math.cos(a), fy + ry * math.sin(a)
        if abs(x - HX) < .36: continue                                        # the gate's gap for the path
        pts.append((x, y))
        fence += [rbox('picket', (x, y, .2), (.055, .03, .36), 'Trim', .3), cone('picket tip', (x, y, .41), .038, 0, .07, 'Trim', 4)]
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        if math.hypot(bx - ax, by - ay) > .5: continue
        for z in (.12, .28): fence.append(rod('rail', (ax, ay, z), (bx, by, z), .014, 'Trim', 6))
    names.append(part('hs_fence', fence))
    garden = []
    for k in range(6):  # path stones from the gate to the steps
        yy = -2.45 + k * .3; garden.append(ball('path stone', (HX + .08 * math.sin(k * 1.7), yy, .02), (.2, .14, .035), 'Pebble', 12, 6))
    gx, gy = X1 + .75, Y0 - .55
    garden.append(rbox('soil bed', (gx, gy, .04), (.8, .6, .1), 'Soil', .3))
    garden.append(rbox('bed edge', (gx, gy - .31, .06), (.84, .04, .12), 'Plank', .3))
    for r in range(3):
        for k in range(4):
            x, y = gx - .27 + k * .18, gy - .18 + r * .18
            if r == 1 and k % 2: garden.append(ball('cabbage', (x, y, .14), (.08, .08, .07), 'Cabbage', 10, 6))
            else: garden += [cone('carrot top', (x, y, .1), .02, 0, .04, 'Carrot', 6), cone('carrot leaves', (x, y, .17), .035, 0, .1, 'Leaf', 5)]
    garden += [rod('mailbox post', (HX - .55, -2.25, 0), (HX - .55, -2.25, .55), .03, 'Walnut'), rbox('mailbox', (HX - .55, -2.25, .62), (.14, .3, .16), 'Petal red', .4),
               rod('mailbox flag', (HX - .47, -2.2, .6), (HX - .47, -2.2, .78), .01, 'Iron'), rbox('mailbox flag tip', (HX - .45, -2.2, .76), (.05, .01, .04), 'Mustard felt', .3)]
    for (x, y, m) in [(X0 - .5, Y0 - .3, 'Petal pink'), (X0 - .7, Y0 + .3, 'Petal yellow'), (X1 + .4, Y1 - .2, 'Petal white')]:
        garden.append(ball('bush', (x, y, .18), (.24, .2, .2), 'Leaf dark', 12, 8))
        for k in range(4): garden.append(ball('bush flower', (x + .12 * math.cos(k * 1.6), y - .12, .28 + .04 * (k % 2)), (.035, .035, .03), m, 8, 5))
    names.append(part('hs_garden', garden))
    # The finale: smoke from the chimney, lit windows, a wreath on the door and a mat at the step.
    finale = []
    for k, (dx, dz, r) in enumerate([(0, .78, .11), (.1, 1.0, .15), (.24, 1.26, .2)]):
        finale.append(ball('smoke', (cx + dx, cy, roof_z + dz), (r, r * .9, r * .85), 'Cream felt', 14, 9))
    for (x, y) in WINDOWS:
        finale.append(cyl('window light', (x, y - .035, WIN_Z), WIN_R - .02, .012, 'Window glow', 24, (math.pi / 2, 0, 0)))
    finale.append(cyl('door window light', (HX, Y0 - .052, FZ + DOOR_H - .28), .075, .006, 'Window glow', 20, (math.pi / 2, 0, 0)))
    for k in range(12):
        a = k * 2 * math.pi / 12; finale.append(ball('wreath leaf', (HX + .14 * math.cos(a), Y0 - .075, FZ + .72 + .14 * math.sin(a)), (.045, .025, .04), 'Leaf' if k % 2 else 'Leaf dark', 8, 5))
    finale += [ball('wreath bow', (HX, Y0 - .09, FZ + .6), (.05, .025, .035), 'Petal red', 8, 5),
               rbox('doormat', (HX, Y0 - .24, FZ + .003), (.5, .3, .012), 'Rust felt', .3)]
    names.append(part('hs_finale', finale))
    return names, (cx, cy, roof_z)

BENCH = (-.85, -1.15, 15)   # inside the fence, left of the path: Moku has its tea here

# ── Build everything.
part('plot', plot(), 60000)
th, chimney = house()
assert len(th) == 24, len(th)
site = [
    part('site_start', plan_board() + lumber(1.95, -1.35) + toolbox(1.25, -1.75) + sawhorse(2.25, -.55) + tent()),
    part('site_frame', plan_board() + lumber(1.95, -1.35, 2) + toolbox(1.25, -1.75) + sawhorse(2.25, -.55) + tent() + scaffold(1)),
    part('site_walls', plan_board() + lumber(2.0, -1.4, 1) + toolbox(1.25, -1.75) + tent() + scaffold(1) + scaffold(-1)),
    part('site_roof', plan_board() + toolbox(1.25, -1.75) + tent() + scaffold(1) + ladder_to_roof() + bench(*BENCH)),
    part('site_tidy', plan_board() + lumber(2.0, -1.4, 1) + tent() + bench(*BENCH)),
    part('site_done', plan_board() + bench(*BENCH) + young_tree(-2.0, .8) + young_tree(2.2, 1.3, .8)),
]
terrain = [slot(n) for n in site]
items = [slot(n) for n in th]
stages = [
    {'threshold': 0, 'room': 'ground', 'structure': [], 'items': items[0:4]},
    {'threshold': 40, 'room': 'frame', 'structure': [], 'items': items[4:8]},
    {'threshold': 80, 'room': 'walls', 'structure': [], 'items': items[8:14]},
    {'threshold': 140, 'room': 'roof', 'structure': [], 'items': items[14:18]},
    {'threshold': 180, 'room': 'home', 'structure': [], 'items': items[18:24]},
    {'threshold': 240, 'room': 'complete', 'structure': [], 'items': [], 'light': point((LAMP[0], LAMP[1] - .3, LAMP[2]))},
]
assert [len(s['items']) for s in stages] == [4, 4, 6, 4, 6, 0]
direction = Vector((-.34, -1.0, .42)).normalized()
cams = []
for threshold, target, distance in [(0, (-.2, -.1, .35), 6.6), (40, (0, .1, .7), 7.4), (80, (.1, .2, .95), 8.2), (140, (.15, .2, 1.1), 8.8), (180, (.15, .05, 1.0), 9.4)]:
    t = Vector(target); cams.append({'threshold': threshold, 'target': point(t), 'from': point(t + direction * distance)})
moku = {  # [x, y, z, turn°] in RealityKit space; Moku is drawn at mokuScale, a size that fits through the door
    'door': point((-.85, -1.05, 0)) + [20], 'early': point((-.8, -1.0, 0)) + [25],
    'focus': point((X1 + .15, Y0 - .6, 0)) + [-40], 'break': point((BENCH[0], BENCH[1] - .02, .27)) + [BENCH[2]],
    'away': point((-1.72, .3, 0)) + [30], 'drift': point((HX, -2.0, 0)) + [0],
}
layout = {'schemaVersion': 1, 'thresholds': THRESHOLDS, 'rooms': STAGES, 'pointsPerItem': 10,
          'note': "Today's house: points are focused minutes today; one piece per 10 minutes; the house is done at 4 hours.",
          'homes': {'dayhouse': {'base': [slot('plot')], 'terrain': terrain, 'stages': stages, 'moku': moku, 'bulbs': [], 'stars': [], 'mokuScale': 0.6, 'cameras': cams}}}
(OUT / 'layout.json').write_text(json.dumps(layout) + '\n')
(OUT / 'manifest.json').write_text(json.dumps({'parts': H.MANIFEST}, indent=1) + '\n')
print('HOUSE_KIT', len(H.MANIFEST), 'parts', sum(p['triangles'] for p in H.MANIFEST), 'triangles')
