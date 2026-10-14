"""Moku's smiling shapes (docs/specs/characters-perfect.md, "Moku: built"), in one place for both the build
(species_moku.morph) and patch_face.py, which rewrites just these shapes in an exported model without a rebuild.

Charles (2026-10-04): "sometimes it looks like moku isnt even smiling". At the size the app shows Moku (about 100 px
tall) v0's happy eyes were nearly flat lines (an arch of 0.014 across a 0.146-wide eye), so a happy Moku read as one
with its eyes shut. The v0 face stays (the hairline w, the same eyes and nose); only how far the closed happy eye
bows changes, so it reads as a smile (^ ^), with a stroke a touch bolder than a blink's line.

Every function takes a point in Blender's model space (z up, the face toward -y) and the side (1 left, -1 right),
and returns the moved point's (x, y, z).
"""
EYE_X, EYE_Z, EYE_HALF_WIDTH = .134, .578, .073

# The closed happy eye: v0 squashed the eye to 2.5% of its height and bowed it .014; now 7% and .04.
HAPPY_SQUASH, HAPPY_ARCH = .07, .04


def happy_eye(x, y, z, s):
    """eyes_happy for the eye, pupil and catchlights: the eye closes into a bowed arc (^)."""
    u = min(1, ((x - s * EYE_X) / EYE_HALF_WIDTH) ** 2)
    return x, y, EYE_Z + (z - EYE_Z) * HAPPY_SQUASH + HAPPY_ARCH * (1 - u)

# The smiling lower lid: v0 cut the eye's bottom flat at .554 (a sixth of its height) with a .007 bump, which reads at
# 100 px as nothing, or as a sleepy half-moon. Now the lid rises in a curve, highest in the middle (the cheek pushing
# up under the eye), so a smiling eye is round on top and curved underneath.
LID_FLOOR, LID_ARCH = .548, .03


def smile_lower_lid(x, y, z, s):
    """lid_smile_lower for the eye, pupil and catchlights: whatever is under the curved lid is pushed up onto it."""
    u = min(1, ((x - s * EYE_X) / EYE_HALF_WIDTH) ** 2)
    return x, y, max(z, LID_FLOOR + LID_ARCH * (1 - u))
