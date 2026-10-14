"""Tetsu's home: a little rocket on a launch pad, built with focused minutes (docs/specs/moku-and-friends.md).

Tetsu, the desk robot, builds a new rocket every day. It keeps the cottage's contract (companion_home.py): one piece per
10 focused minutes, 24 pieces in 5 stages, done at 4 hours.
  0-40 min    the pad: a chalk ring, the concrete pad, hazard stripes, the launch ring
  40-80 min   the gantry: its legs, its top, the crew walkway, the fuel lines
  80-140 min  the hull: the engine, the lower and upper hull, the round hatch, the portholes, the amber bands
  140-180 min fins and nose: the left, right and back fins, the nose cone
  180-240 min launch-ready: the beacon, the pad lights, the countdown clock, the radio dish, the mission flag, and the
              finishing touches (lit portholes, steam at the pad)
The site changes with it (terrain): the blueprint board, crates, the toolbox, a cable reel and Tetsu's charging dock at
first, a hoist while the hull and nose go up, the control desk once the rocket is done. Brushed off-white, slate and
one amber accent, as Tetsu is.

Run: Blender --background --factory-startup --python-exit-code 1 --python assets/src/rocket_kit.py"""
import sys, math, random
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ROOT, reset, finish
import home_parts as H
from home_parts import rbox, ball, cyl, cone, rod, curve, lathe
import companion_home as CH
from companion_home import lawn_z, M, placed, prism, circle, cloth
import bpy
from mathutils import Vector, Matrix

KEY = 'tetsu'
OUT = ROOT / 'world' / KEY; OUT.mkdir(parents=True, exist_ok=True)
reset(); CH.setup(); rng = random.Random(1)

RX, RY = .45, .3                 # the rocket's axis; the plot's front is -y
PZ = .22                         # the pad's top
HR = .44                         # the hull's radius
H0 = PZ + .42                    # the hull's foot, on the engine
H1 = H0 + .72                    # the seam between the lower and upper hull
H2 = H1 + .72                    # the hull's top, under the nose cone
NOSE = .95                       # the nose cone's height
GANTRY_AZ, GD = 150, 1.8         # where the gantry stands, seen from the rocket (degrees; 270 is the front), and how far
GX, GY = RX + GD * math.cos(math.radians(GANTRY_AZ)), RY + GD * math.sin(math.radians(GANTRY_AZ))
GW, GTOP = .5, 2.3               # the gantry's width and the top deck's height
WALK = H1 + .24                  # the crew walkway's deck
FINS = {'left': 191, 'right': 311, 'back': 71}
HATCH_AZ, PORT_AZ = 228, 262
CLAMPS = (11, 131, 251)          # between the fins
LIGHTS = (30, 120, 210, 300)     # the pad lights, on the rim

def az(a): return Vector((math.cos(math.radians(a)), math.sin(math.radians(a)), 0))
def around(a, r, z=0): return Vector((RX, RY, z)) + az(a) * r
def on_hull(name, objs, a, z):
    """Parts built facing -y with the hull's surface at y = 0, turned to face azimuth `a` on the hull at height z."""
    p = around(a, HR, z); return placed(name, objs, M(p.x, p.y, p.z, a - 270))
def turned(name, profile, material, x, y, z, segments=40):
    o = lathe(name, profile, material, segments); o.location = (x, y, z); return o
def ring(name, r, z, material, thick=.04, height=.08):
    """A band round the hull: a soft ring of radius r at height z."""
    return turned(name, [(r - .01, -height / 2), (r + thick * .6, -height / 2), (r + thick, -height / 4), (r + thick, height / 4), (r + thick * .6, height / 2), (r - .01, height / 2), (r - .01, -height / 2)], material, RX, RY, z)

# ── The plot: the cottage's felt island, kept clear for the pad, the gantry, the site and a gravel path.
def keep_clear(x, y):
    if math.hypot(x - RX, y - RY) < 1.55: return True                      # the pad
    if math.hypot(x - GX, y - GY) < .7: return True                        # the gantry
    if -2.45 < x < -1.2 and -1.5 < y < -.4: return True                    # the blueprint board
    if 1.0 < x < 2.7 and -2.1 < y < -.6: return True                       # crates, toolbox, the control desk
    if -2.7 < x < -1.6 and -.1 < y < .9: return True                       # Tetsu's charging dock
    if math.hypot(x - 2.15, y - .95) < .5: return True                     # the radio dish
    if math.hypot(x + 1.05, y + .45) < .2: return True                     # the mission flag
    if abs(x - (RX - .1)) < .45 and y < -1.0: return True                  # the path
    return False

def dress(i, x, y):
    z = lawn_z(x, y)
    if i % 7 == 0: return [ball('rock', (x, y, z + .01), (.07, .06, .045), 'Stone', 10, 6)]
    if i % 11 == 0: return [ball('wild flower', (x, y, z + .03), (.028, .028, .02), 'Petal yellow', 8, 5)]
    return CH.tuft(x, y, 'Grass light' if i % 2 else 'Grass deep')

def plot():
    p = CH.lawn(rng, keep_clear, dress, 90)
    for k in range(7):  # a gravel path from the front edge to the pad
        x, y = RX - .1 + .07 * math.sin(k * 1.9), -2.55 + k * .24
        p.append(ball('gravel', (x, y, lawn_z(x, y) - .005), (.17, .12, .03), 'Pebble', 12, 6))
    return p

# ── The site.
def blueprint_board(x=-1.85, y=-.95, turn=-18):
    """The plan: a blueprint of today's rocket on an easel."""
    p = [rbox('board frame', (0, 0, .98), (1.0, .06, .74), 'Walnut', .2), rbox('blueprint', (0, -.035, .98), (.88, .012, .62), 'Indigo felt', .1)]
    for sx in (-.36, .36): p.append(rod('easel leg', (sx, .06, 0), (sx * .9, 0, 1.3), .025, 'Walnut'))
    p.append(rod('easel back leg', (0, .45, 0), (0, .05, 1.25), .022, 'Walnut'))
    p.append(rbox('ledge', (0, -.06, .6), (.95, .1, .03), 'Walnut', .2))
    p.append(rod('chalk', (.18, -.07, .63), (.34, -.07, .64), .012, 'Paper'))
    ink = lambda a, b, r=.007: rod('line', (a[0], -.043, a[1]), (b[0], -.043, b[1]), r, 'Paper', 6)
    bx, bz0, bz1, tip = .07, .78, 1.08, 1.24          # the hull, the nose, the fins
    p += [ink((-bx, bz0), (-bx, bz1)), ink((bx, bz0), (bx, bz1)), ink((-bx, bz0), (bx, bz0)), ink((-bx, bz1), (bx, bz1)),
          ink((-bx, bz1), (0, tip)), ink((0, tip), (bx, bz1)), ink((-bx, bz0 + .1), (-.15, bz0 - .04)), ink((-.15, bz0 - .04), (-bx, bz0)),
          ink((bx, bz0 + .1), (.15, bz0 - .04)), ink((.15, bz0 - .04), (bx, bz0))]
    p.append(circle('porthole line', (0, -.043, .99), .03, Vector((1, 0, 0)), Vector((0, 0, 1)), .006, 'Paper', 16))
    for k in range(3): p.append(ink((.24, 1.18 - k * .06), (.38, 1.18 - k * .06), .005))      # notes in the margin
    p.append(circle('margin orbit', (-.3, -.043, 1.12), .07, Vector((1, 0, 0)), Vector((0, 0, 1)), .005, 'Paper', 20))
    return placed('blueprint board', p, M(x, y, lawn_z(x, y) - .02, turn))

def crates(x, y, count=3, turn=12):
    p = []
    spots = [(0, 0, 0, .42), (.46, .05, 0, .36), (.18, .02, .42, .34)][:count]
    for (dx, dy, dz, s) in spots:
        p.append(rbox('crate', (dx, dy, dz + s / 2), (s, s, s), 'Plank', .12))
        for k in (-1, 1):
            p.append(rbox('crate slat', (dx + k * s * .32, dy - s / 2 - .005, dz + s / 2), (.05, .012, s * .92), 'Plank dark', .3))
        p.append(rbox('crate band', (dx, dy - s / 2 - .008, dz + s / 2), (s * .9, .012, .05), 'Plank dark', .3))
    return placed('crates', p, M(x, y, lawn_z(x, y) - .02, turn))

def toolbox(x=1.3, y=-1.75, turn=-20):
    p = [rbox('toolbox', (0, 0, .09), (.36, .18, .16), 'Rust felt', .3), rod('handle', (-.1, 0, .2), (.1, 0, .2), .014, 'Iron'),
         rod('handle post', (-.1, 0, .17), (-.1, 0, .21), .012, 'Iron'), rod('handle post', (.1, 0, .17), (.1, 0, .21), .012, 'Iron'),
         rbox('latch', (0, -.092, .14), (.06, .01, .04), 'Brass', .3),
         rod('wrench', (.26, -.08, .015), (.48, .0, .015), .014, 'Steel'), cyl('wrench jaw', (.5, .01, .015), .035, .02, 'Steel', 12)]
    return placed('toolbox', p, M(x, y, lawn_z(x, y) - .015, turn))

def cable_reel(x=2.35, y=-.15, turn=30):
    p = [cyl('reel side', (-.14, 0, .26), .26, .04, 'Plank', 24, (0, math.pi / 2, 0)), cyl('reel side', (.14, 0, .26), .26, .04, 'Plank', 24, (0, math.pi / 2, 0)),
         cyl('cable', (0, 0, .26), .19, .24, 'Ink', 24, (0, math.pi / 2, 0)), cyl('reel hub', (0, 0, .26), .05, .34, 'Plank dark', 12, (0, math.pi / 2, 0))]
    p.append(curve('cable end', [(0, -.18, .2), (0, -.3, .03), (.1, -.5, .02), (.05, -.7, .02)], .018, 'Ink'))
    return placed('cable reel', p, M(x, y, lawn_z(x, y) - .02, turn))

def charging_dock(x=-2.15, y=.38, turn=28):
    """Tetsu's camp until the rocket is done: a padded charging dock with a glowing strip and a plug."""
    p = [rbox('dock base', (0, 0, .06), (.62, .5, .12), 'Slate light', .3), rbox('dock pad', (0, .02, .14), (.52, .4, .05), 'Indigo felt', .6),
         rbox('dock back', (0, .24, .36), (.62, .08, .5), 'Slate light', .3), rbox('dock strip', (0, .195, .5), (.4, .02, .05), 'Lamp glow', .4),
         ball('dock light', (.22, .195, .36), (.03, .02, .03), 'Lamp glow', 10, 6)]
    p.append(curve('dock cable', [(.31, .24, .1), (.45, .3, .02), (.7, .1, .02), (.8, -.2, .02)], .018, 'Ink'))
    p.append(rbox('plug', (.82, -.25, .03), (.06, .1, .05), 'Slate', .4))
    return placed('charging dock', p, M(x, y, lawn_z(x, y) - .02, turn))

def hoist():
    """An A-frame hoist beside the rocket while the hull and nose go up, a hook hanging from its arm."""
    x, y0, y1, top = RX + 1.55, RY - .35, RY + .45, 2.75
    p = []
    for yy in (y0, y1):
        p += [rod('hoist leg', (x + .3, yy, lawn_z(x + .3, yy) - .03), (x, (y0 + y1) / 2, top), .035, 'Mustard felt'),
              rod('hoist leg', (x - .25, yy, lawn_z(x - .25, yy) - .03), (x, (y0 + y1) / 2, top), .035, 'Mustard felt')]
    ym = (y0 + y1) / 2
    p += [rod('hoist arm', (x + .15, ym, top - .05), (RX + HR + .2, ym, top + .05), .03, 'Mustard felt'),
          rod('hoist brace', (x, ym, top - .55), (RX + HR + .45, ym, top + .02), .022, 'Mustard felt'),
          rbox('hoist block', (RX + HR + .22, ym, top - .02), (.08, .08, .1), 'Slate', .3),
          rod('hoist rope', (RX + HR + .22, ym, top - .07), (RX + HR + .22, ym, top - .62), .006, 'Paper'),
          curve('hook', [(RX + HR + .22, ym, top - .62), (RX + HR + .22, ym, top - .7), (RX + HR + .28, ym, top - .72), (RX + HR + .3, ym, top - .66)], .012, 'Iron'),
          rod('hoist crossbar', (x - .2, y0 + .06, .9), (x - .2, y1 - .06, .9), .02, 'Mustard felt')]
    return p

def control_desk(x=2.05, y=-1.35, turn=-32):
    """Mission control once the rocket is done: a little desk with a glowing screen, buttons and a stool."""
    p = [rbox('desk', (0, 0, .36), (.8, .44, .06), 'Slate', .25)]
    for sx in (-.34, .34): p.append(rbox('desk side', (sx, 0, .17), (.06, .4, .34), 'Slate', .3))
    p += [rbox('console', (0, .1, .48), (.72, .26, .14), 'Slate light', .3), rbox('screen', (0, .16, .7), (.46, .05, .3), 'Slate', .25),
          rbox('screen glow', (0, .132, .7), (.4, .012, .24), 'Window glow', .1)]
    p[-3].rotation_euler.x = math.radians(-18)
    for k, m in enumerate(['Mustard felt', 'Petal red', 'Grass light', 'Mustard felt']):
        p.append(ball('button', (-.24 + k * .16, .0, .57), (.025, .025, .015), m, 10, 6))
    p += [cyl('stool seat', (0, -.42, .3), .16, .05, 'Mustard felt', 20), rod('stool post', (0, -.42, .28), (0, -.42, .02), .025, 'Slate'),
          cyl('stool foot', (0, -.42, .015), .13, .03, 'Slate', 18)]
    return placed('control desk', p, M(x, y, lawn_z(x, y) - .02, turn))

# ── The rocket, piece by piece (24 pieces, 10 focused minutes each). Each returns (objects, anchor).
def chalk_ring():
    p = []
    pts = [around(k * 360 / 64, 1.32) for k in range(65)]
    p.append(curve('chalk ring', [(v.x, v.y, lawn_z(v.x, v.y) + .004) for v in pts], .014, 'Paper', 1))
    for a in (45, 135, 225, 315):                                 # marker cones with a white band
        v = around(a, 1.32); z = lawn_z(v.x, v.y) - .01
        p += [cone('marker cone', (v.x, v.y, z + .09), .075, .012, .18, 'Rust felt', 16), cyl('marker band', (v.x, v.y, z + .1), .052, .03, 'Paper', 16),
              rbox('marker foot', (v.x, v.y, z + .01), (.16, .16, .02), 'Rust felt', .3)]
    for a in (0, 90):                                             # a chalk cross where the rocket will stand
        p.append(rod('chalk cross', tuple(around(a, .5, lawn_z(RX, RY) + .005)), tuple(around(a + 180, .5, lawn_z(RX, RY) + .005)), .012, 'Paper'))
    return p, (RX, RY, lawn_z(RX, RY))

def concrete_pad():
    p = [turned('pad', [(0, -.04), (1.16, -.04), (1.2, .0), (1.18, .17), (1.13, PZ), (0, PZ)], 'Stone', RX, RY, 0, 48),
         turned('pad top', [(0, PZ - .01), (.97, PZ - .01), (.98, PZ + .008), (0, PZ + .008)], 'Slate', RX, RY, 0, 48)]
    return p, (RX, RY, 0)

def hazard_stripes():
    p = []
    n = 36
    for k in range(n):                                            # amber and dark blocks round the rim
        a = k * 360 / n; v = around(a, 1.055, PZ + .008)
        b = rbox('stripe', tuple(v), (.13, .17, .016), 'Mustard felt' if k % 2 else 'Ink', .2, 1); b.rotation_euler.z = math.radians(a); p.append(b)
    p.append(circle('landing circle', (RX, RY, PZ + .012), .66, Vector((1, 0, 0)), Vector((0, 1, 0)), .014, 'Paper', 48))
    for a in (0, 90, 180, 270):
        v = around(a, .82, PZ + .012); b = rbox('tick', tuple(v), (.16, .03, .008), 'Paper', .2, 1); b.rotation_euler.z = math.radians(a); p.append(b)
    return p, (RX, RY, PZ)

def launch_ring():
    p = [cyl('flame grate', (RX, RY, PZ + .018), .42, .02, 'Ink', 32),
         turned('launch ring', [(.36, 0), (.5, 0), (.52, .05), (.5, .1), (.37, .1), (.35, .05), (.36, 0)], 'Steel', RX, RY, PZ + .005, 40)]
    for k in range(8):                                            # grate bars
        a = k * 22.5; p.append(rod('grate bar', tuple(around(a, .38, PZ + .03)), tuple(around(a + 180, .38, PZ + .03)), .008, 'Slate'))
    for a in CLAMPS:                                              # hold-down clamps, capped in amber
        v = around(a, .5); c = rbox('clamp', (v.x, v.y, PZ + .12), (.13, .11, .2), 'Slate', .25); c.rotation_euler.z = math.radians(a); p.append(c)
        cap = rbox('clamp cap', (v.x, v.y, PZ + .235), (.14, .12, .04), 'Mustard felt', .3); cap.rotation_euler.z = math.radians(a); p.append(cap)
    return p, (RX, RY, PZ)

def gantry_frame(z0, z1, girts, footing=False):
    """A square lattice section of the gantry from z0 to z1, built facing the rocket (+x), then set in place."""
    h = GW / 2; corners = [(-h, -h), (h, -h), (h, h), (-h, h)]
    p = [rbox('gantry post', (x, y, (z0 + z1) / 2), (.075, .075, z1 - z0), 'Slate', .25) for x, y in corners]
    levels = [z0 + .02] + girts
    for z in girts:
        for i in range(4):
            (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
            p.append(rod('girt', (ax, ay, z), (bx, by, z), .022, 'Slate'))
    for za, zb in zip(levels[:-1], levels[1:]):
        for i in range(4):
            (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
            p.append(rod('brace', (ax, ay, za + .04), (bx, by, zb - .04), .014, 'Slate light'))
            p.append(rod('brace', (bx, by, za + .04), (ax, ay, zb - .04), .014, 'Slate light'))
    if footing: p.append(rbox('gantry footing', (0, 0, lawn_z(GX, GY)), (GW + .3, GW + .3, .14), 'Stone', .3))
    return p

def gantry_place(name, p):
    return placed(name, p, M(GX, GY, 0, GANTRY_AZ - 180))

def gantry_legs():
    p = gantry_frame(.06, 1.6, [.82, 1.6], footing=True)
    p += [rbox('ladder rail', (-GW / 2 - .02, s * .1, .85), (.02, .02, 1.6), 'Steel', .3) for s in (-1, 1)]
    for k in range(9): p.append(rod('rung', (-GW / 2 - .02, -.1, .15 + k * .17), (-GW / 2 - .02, .1, .15 + k * .17), .009, 'Steel'))
    return gantry_place('gantry legs', p), (GX, GY, lawn_z(GX, GY) - .02)

def gantry_top():
    p = gantry_frame(1.6, GTOP, [GTOP])
    p.append(rbox('top deck', (0, 0, GTOP + .03), (GW + .16, GW + .16, .05), 'Slate', .3))
    h = GW / 2 + .06
    for (ax, ay), (bx, by) in [((-h, -h), (h, -h)), ((h, -h), (h, h)), ((h, h), (-h, h)), ((-h, h), (-h, -h))]:
        p.append(rod('top rail', (ax, ay, GTOP + .28), (bx, by, GTOP + .28), .014, 'Mustard felt'))
    for x, y in [(-h, -h), (h, -h), (h, h), (-h, h)]: p.append(rod('rail post', (x, y, GTOP + .05), (x, y, GTOP + .28), .014, 'Mustard felt'))
    p += [rod('mast', (0, 0, GTOP + .05), (0, 0, GTOP + .3), .025, 'Steel'), cyl('mast cap', (0, 0, GTOP + .31), .045, .03, 'Slate', 14)]
    return gantry_place('gantry top', p), (GX, GY, 1.6)

def crew_walkway():
    """The arm from the gantry to the upper hull: a deck with amber railings and a strut."""
    far = GD - HR - .035; near = GW / 2 - .02; mid = (far + near) / 2; length = far - near
    p = [rbox('walkway deck', (mid, 0, WALK - .025), (length, .32, .05), 'Slate', .3),
         rbox('walkway bumper', (far - .02, 0, WALK + .12), (.045, .26, .26), 'Ink', .5),
         rod('walkway strut', (near + .02, 0, WALK - .55), (mid + .1, 0, WALK - .05), .02, 'Slate')]
    for s in (-1, 1):
        p += [rod('walkway rail', (near, s * .15, WALK + .3), (far - .05, s * .15, WALK + .3), .013, 'Mustard felt'),
              rod('walkway rail', (near, s * .15, WALK + .15), (far - .05, s * .15, WALK + .15), .01, 'Mustard felt')]
        for x in (near + .04, mid, far - .06): p.append(rod('walkway post', (x, s * .15, WALK), (x, s * .15, WALK + .3), .012, 'Mustard felt'))
    anchor = Vector((GX, GY, WALK)) + az(GANTRY_AZ - 180) * mid
    return gantry_place('crew walkway', p), tuple(anchor)

def fuel_lines():
    """Two hoses from the gantry, over the lawn and the pad's rim, through a valve into the launch ring."""
    d = (Vector((RX, RY, 0)) - Vector((GX, GY, 0))).normalized(); side = Vector((-d.y, d.x, 0))
    p = []
    for off, m in ((-.07, 'Ink'), (.07, 'Rust felt')):
        pts = []
        for r, z in [(GD - .12, .55), (GD - .2, .3), (GD - .3, None), (1.27, None), (1.14, PZ + .05), (.98, PZ + .06), (.62, PZ + .1)]:
            v = Vector((RX, RY, 0)) - d * r + side * off
            pts.append((v.x, v.y, z if z is not None else lawn_z(v.x, v.y) + .03))
        p.append(curve('fuel line', pts, .032, m, 6))
    v = around(GANTRY_AZ, .98, PZ); p += [rbox('valve box', (v.x, v.y, PZ + .06), (.16, .2, .12), 'Slate light', .3), cyl('valve wheel', (v.x, v.y, PZ + .15), .06, .02, 'Petal red', 16)]
    return p, None

def engine():
    p = [turned('engine bell', [(0, .1), (.24, .04), (.3, 0), (.315, .02), (.24, .17), (.16, .29), (.15, .34), (.3, .37), (.37, .4), (0, .405)], 'Slate', RX, RY, PZ + .02, 36),
         cyl('throat', (RX, RY, PZ + .035), .2, .01, 'Ink', 28)]
    for k in range(4):
        a = 45 + k * 90; p.append(rod('engine strut', tuple(around(a, .17, PZ + .3)), tuple(around(a, .32, PZ + .41)), .015, 'Steel'))
    return p, (RX, RY, PZ + .02)

def lower_hull():
    p = [turned('lower hull', [(0, 0), (.46, 0), (.48, .03), (.465, .1), (HR, .2), (HR, .7), (HR - .01, .72), (0, .72)], 'Cream felt', RX, RY, H0, 48)]
    for k in range(10):                                           # a row of rivets at the skirt
        v = around(k * 36 + 18, HR + .005, H0 + .24); p.append(ball('rivet', tuple(v), (.016, .016, .016), 'Steel', 8, 5))
    return p, (RX, RY, H0)

def upper_hull():
    p = [turned('upper hull', [(HR - .01, 0), (HR, .02), (HR, .68), (HR - .01, .72), (HR - .05, .72), (HR - .06, .69), (HR - .06, .58), (0, .58)], 'Cream felt', RX, RY, H1, 48)]
    p.append(turned('hull seam', [(HR - .02, -.012), (HR + .006, -.012), (HR + .006, .012), (HR - .02, .012), (HR - .02, -.012)], 'Trim', RX, RY, H1 + .36, 48))
    return p, (RX, RY, H1)

def round_hatch():
    r = .17
    p = [cyl('hatch', (0, 0, 0), r, .08, 'Slate light', 32, (math.pi / 2, 0, 0)),
         circle('hatch rim', (0, -.042, 0), r + .01, Vector((1, 0, 0)), Vector((0, 0, 1)), .02, 'Steel', 32),
         circle('hatch wheel', (0, -.06, -.01), .07, Vector((1, 0, 0)), Vector((0, 0, 1)), .011, 'Mustard felt', 24),
         rod('wheel spoke', (-.07, -.06, -.01), (.07, -.06, -.01), .008, 'Mustard felt'), rod('wheel spoke', (0, -.06, -.08), (0, -.06, .06), .008, 'Mustard felt'),
         cyl('hatch window', (0, -.035, .1), .045, .02, 'Ink', 18, (math.pi / 2, 0, 0))]
    for k in range(8):
        a = k * math.pi / 4 + math.pi / 8; p.append(ball('hatch bolt', (math.cos(a) * (r - .025), -.045, math.sin(a) * (r - .025)), (.012, .012, .012), 'Steel', 8, 5))
    return on_hull('round hatch', p, HATCH_AZ, H0 + .37), tuple(around(HATCH_AZ, HR, H0 + .37 - r))

def portholes():
    p = []
    for z in (.22, .5):
        p += [cyl('porthole glass', (0, 0, z), .09, .07, 'Ink', 28, (math.pi / 2, 0, 0)),
              circle('porthole rim', (0, -.035, z), .1, Vector((1, 0, 0)), Vector((0, 0, 1)), .024, 'Brass', 32),
              ball('porthole shine', (-.035, -.04, z + .035), (.018, .006, .014), 'Paper', 8, 5)]
    return on_hull('portholes', p, PORT_AZ, H1), tuple(around(PORT_AZ, HR, H1 + .12))

def amber_bands():
    p = [ring('band', HR + .005, H0 + .15, 'Mustard felt', .03, .07), ring('band', HR, H1, 'Mustard felt', .028, .07), ring('band', HR, H2 - .04, 'Mustard felt', .028, .07)]
    return p, (RX, RY, H0 + .115)

def fin(side):
    """A slate fin that reaches down to the pad as a leg, along the lower hull."""
    a = FINS[side]
    outline = [(HR - .04, H0 + .62), (HR - .04, H0 + .02), (.6, PZ + .1), (.76, PZ + .005), (.88, PZ + .005), (.9, PZ + .1), (.86, PZ + .34), (.62, H0 + .2)]
    f = prism('fin', outline, .075, 'Slate', .018)
    stripe = prism('fin tip', [(.83, PZ + .19), (.9, PZ + .19), (.88, PZ + .3), (.81, PZ + .38)], .082, 'Mustard felt', .01)
    o = H.join('fin', [f, stripe]); o.matrix_world = M(RX, RY, 0, a) @ o.matrix_world
    return [o], tuple(around(a, .82, PZ))

def nose_cone():
    rho = (HR * HR + NOSE * NOSE) / (2 * HR)
    prof = [(0, -.02), (HR - .01, -.02)] + [(math.sqrt(max(0, rho * rho - z * z)) + HR - rho, z) for z in [NOSE * k / 14 for k in range(14)]] + [(0, NOSE)]
    p = [turned('nose cone', prof, 'Cream felt', RX, RY, H2, 48), ball('nose tip', (RX, RY, H2 + NOSE - .02), (.055, .055, .07), 'Mustard felt', 14, 8)]
    return p, (RX, RY, H2)

# Launch-ready.
def beacon():
    z = GTOP + .31
    p = [cyl('beacon base', (0, 0, z + .02), .075, .04, 'Slate', 16), ball('beacon', (0, 0, z + .12), (.09, .09, .11), 'Lamp glow', 16, 10),
         cyl('beacon cap', (0, 0, z + .235), .07, .02, 'Slate', 16)]
    for k in range(3):
        a = k * 2 * math.pi / 3; p.append(rod('beacon cage', (.09 * math.cos(a), .09 * math.sin(a), z + .03), (.09 * math.cos(a), .09 * math.sin(a), z + .225), .008, 'Slate'))
    return gantry_place('beacon', p), (GX, GY, z)

def pad_lights():
    p = []
    for a in LIGHTS:
        v = around(a, 1.055, PZ + .016)
        p += [cyl('lamp base', (v.x, v.y, v.z + .025), .06, .05, 'Slate', 16), ball('pad lamp', (v.x, v.y, v.z + .065), (.05, .05, .045), 'Lamp glow', 14, 8)]
    return p, (RX, RY, PZ)

DIGITS = {'1': 'bc', '0': 'abcdef', 'T': 'ag'}
def countdown_clock(x=.95, y=-1.3, turn=-19):
    """A board on two posts counting down: T-10, in glowing segments."""
    p = [rbox('clock board', (0, 0, .82), (.78, .07, .36), 'Slate', .2), rbox('clock face', (0, -.037, .82), (.7, .01, .28), 'Ink', .1)]
    for sx in (-.3, .3): p.append(rod('clock post', (sx, .02, 0), (sx, .02, .66), .025, 'Slate'))
    p.append(rbox('clock lip', (0, -.02, 1.02), (.82, .1, .03), 'Mustard felt', .3))
    w, h, t = .09, .17, .022
    def segs(d, cx):
        out = []
        pos = {'a': (cx, .82 + h / 2, w, t), 'g': (cx, .82, w, t), 'd': (cx, .82 - h / 2, w, t),
               'b': (cx + w / 2, .82 + h / 4, t, h / 2), 'c': (cx + w / 2, .82 - h / 4, t, h / 2), 'f': (cx - w / 2, .82 + h / 4, t, h / 2), 'e': (cx - w / 2, .82 - h / 4, t, h / 2)}
        for s in DIGITS[d]:
            sx, sz, sw, sh = pos[s]
            if d == 'T' and s == 'g': out.append(rbox('segment', (sx, -.045, .82), (t, .01, h), 'Lamp glow', .2)); continue
            out.append(rbox('segment', (sx, -.045, sz), (sw, .01, sh), 'Lamp glow', .2))
        return out
    p += segs('T', -.22) + [rbox('segment', (-.1, -.045, .82), (.05, .01, t), 'Lamp glow', .2)] + segs('1', .01) + segs('0', .17)
    z = lawn_z(x, y) - .02
    return placed('countdown clock', p, M(x, y, z, turn)), (x, y, z)

def radio_dish(x=2.15, y=.95):
    z = lawn_z(x, y) - .02
    p = []
    for k in range(3):
        a = k * 2 * math.pi / 3 + .4; p.append(rod('dish leg', (x + .3 * math.cos(a), y + .3 * math.sin(a), z), (x, y, z + .62), .02, 'Slate'))
    tilt = M(x, y, z + .66, 30) @ Matrix.Rotation(math.radians(-40), 4, 'X')   # the dish looks up at the sky, to the back
    dish = lathe('dish', [(0, 0), (.12, .01), (.24, .045), (.34, .1), (.36, .12), (.33, .12), (.22, .07), (.1, .03), (0, .025)], 'Steel', 32)
    dish.matrix_world = tilt
    p += [cyl('dish mount', (x, y, z + .63), .05, .07, 'Slate', 14), dish,
          rod('dish feed', tuple(tilt @ Vector((0, 0, .02))), tuple(tilt @ Vector((0, 0, .36))), .012, 'Slate'),
          ball('feed tip', tuple(tilt @ Vector((0, 0, .38))), (.03, .03, .03), 'Mustard felt', 10, 6)]
    return p, (x, y, z)

def mission_flag(x=-1.05, y=-.45):
    z = lawn_z(x, y) - .02
    fw, fh = .52, .32
    flag = cloth('flag', (x + .03, y, z + 1.42), fw, fh, 'Mustard felt')
    emblem = cyl('flag emblem', (x + .03 + fw * .45, y + .035 * math.sin(.45 * math.pi * 1.6) - .016, z + 1.42 - fh / 2), .085, .012, 'Slate', 24, (math.pi / 2, 0, 0))
    star = ball('emblem star', (x + .03 + fw * .45, y + .035 * math.sin(.45 * math.pi * 1.6) - .024, z + 1.42 - fh / 2), (.03, .008, .03), 'Paper', 10, 6)
    p = [rod('flag pole', (x, y, z), (x, y, z + 1.5), .02, 'Steel'), ball('pole top', (x, y, z + 1.51), (.035, .035, .035), 'Mustard felt', 10, 6), flag, emblem, star,
         cyl('pole foot', (x, y, z + .03), .07, .06, 'Slate', 16)]
    return p, (x, y, z)

def finishing_touches():
    """Lit portholes and hatch window, and steam curling from the pad: ready to go."""
    p = []
    for z in (.22, .5): p.append(cyl('porthole light', (0, -.037, z), .075, .006, 'Window glow', 24, (math.pi / 2, 0, 0)))
    lit = on_hull('porthole lights', p, PORT_AZ, H1)
    hatch = on_hull('hatch light', [cyl('hatch window light', (0, -.047, .1), .037, .006, 'Window glow', 18, (math.pi / 2, 0, 0))], HATCH_AZ, H0 + .37)
    steam = []
    for a, r, s in [(178, .72, .15), (203, .64, .11), (332, .72, .15), (8, .66, .12)]:   # to the sides, clear of the ring
        v = around(a, r, PZ + s * .8); steam.append(ball('steam', tuple(v), (s, s * .9, s * .8), 'Cream felt', 14, 9))
        v2 = around(a + 8, r + .1, PZ + s * 1.7); steam.append(ball('steam', tuple(v2), (s * .7, s * .65, s * .6), 'Cream felt', 12, 8))
    return lit + hatch + steam, (RX, RY, PZ)

# ── Build everything.
pieces = [chalk_ring, concrete_pad, hazard_stripes, launch_ring,
          gantry_legs, gantry_top, crew_walkway, fuel_lines,
          engine, lower_hull, upper_hull, round_hatch, portholes, amber_bands,
          lambda: fin('left'), lambda: fin('right'), lambda: fin('back'), nose_cone,
          beacon, pad_lights, countdown_clock, radio_dish, mission_flag, finishing_touches]
ASSETS = ['rk_chalk', 'rk_pad', 'rk_stripes', 'rk_ring', 'rk_gantry_legs', 'rk_gantry_top', 'rk_walkway', 'rk_fuel',
          'rk_engine', 'rk_hull_lower', 'rk_hull_upper', 'rk_hatch', 'rk_portholes', 'rk_bands',
          'rk_fin_left', 'rk_fin_right', 'rk_fin_back', 'rk_nose', 'rk_beacon', 'rk_pad_lights', 'rk_countdown', 'rk_dish', 'rk_flag', 'rk_finale']
NAMES = {'home': 'Today’s rocket', 'finished': 'Tetsu’s rocket is ready for today. Come see it in Your day.',
         'stages': ['The pad', 'The gantry', 'The hull', 'Fins & nose', 'Launch-ready'],
         'pieces': ['the chalk ring', 'the concrete pad', 'the hazard stripes', 'the launch ring',
                    'the gantry legs', 'the gantry top', 'the crew walkway', 'the fuel lines',
                    'the engine', 'the lower hull', 'the upper hull', 'the round hatch', 'the portholes', 'the amber bands',
                    'the left fin', 'the right fin', 'the back fin', 'the nose cone',
                    'the beacon', 'the pad lights', 'the countdown clock', 'the radio dish', 'the mission flag', 'the finishing touches']}

CH.save(OUT, 'plot', plot(), limit=60000)
built = []
for name, build in zip(ASSETS, pieces):
    built.append(CH.save_piece(OUT, name, *build()))
board, box, reel, dock = blueprint_board, toolbox, cable_reel, charging_dock
site = [
    CH.save(OUT, 'site_start', board() + crates(2.05, -1.1) + box() + reel() + dock(), limit=30000),
    CH.save(OUT, 'site_frame', board() + crates(2.05, -1.1) + box() + reel() + dock(), limit=30000),
    CH.save(OUT, 'site_walls', board() + crates(2.05, -1.1, 2) + box() + dock() + hoist(), limit=30000),
    CH.save(OUT, 'site_roof', board() + crates(2.05, -1.1, 1) + box() + dock() + hoist(), limit=30000),
    CH.save(OUT, 'site_tidy', board() + box() + dock() + control_desk(), limit=30000),
    CH.save(OUT, 'site_done', board() + control_desk() + CH.young_tree(-2.15, .55) + CH.young_tree(2.6, -.3, .8), limit=30000),
]
framings = [(0, (RX - .25, RY - .35, .35), 6.8), (40, (RX - .55, RY, 1.35), 9.4), (80, (RX - .5, RY, 1.4), 9.6),
            (140, (RX - .45, RY, 1.62), 10.0), (180, (RX - .4, RY - .15, 1.66), 10.4)]
actor = {'door': (RX - .9, RY - 1.55, 0, 20), 'early': (RX - 1.1, RY - 1.45, 0, 25), 'focus': (RX + 1.25, RY - 1.2, 0, -40),
         'break': (-2.15, .38, .19, 28), 'away': (-1.9, .9, 0, 30), 'drift': (RX - .1, -2.1, 0, 0)}
CH.write(OUT, KEY, 'plot', site, built, NAMES, around(255, 1.6, .9), framings, actor)
