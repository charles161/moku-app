# Moku and friends — concept notes

**tetsu_character_sheet.png** — Built-in image generation; direction: Moku's warm-paper turnaround, expression and pose layout, with a precise off-white robot in matte felt-like panels, slate joints and restrained amber. Ring-shaped OLED eyes and flexible antennae give Tetsu an earnest personality without a mouth. The boot-up scan lines and segmented battery make its rituals readable. I'd widen the curious eyes further and reduce LED bloom for the tiny desktop model.

**yuzu_character_sheet.png** — Built-in image generation; direction: the same sheet structure with a ginger-and-cream felt cat, green slit pupils, eight expressions and five signature poses. Feline proportions, airplane ears and the deliberate cup push keep Yuzu dry and quietly devoted. I'd round the torso slightly and shorten the visible surface fibres and whiskers to bring it even closer to Moku's dense, short felt.

**tetsu_home_stages.png** — Built-in image generation; direction: five cumulative isometric rocket dioramas on warm paper, with a small felt-smoke lift-off inset. The pad, toolbox and gantry stay visible as the open hull gains its nose, fins and launch lights. Off-white, slate and amber connect it to Tetsu. I'd simplify the gantry rails for desktop readability and soften the inset's bright exhaust into a quieter cream smoke puff.

**yuzu_home_stages.png** — Built-in image generation; direction: five cumulative cardboard-castle dioramas with a rug, bowl, scratching post, paper turrets, bell, yarn and flag. Kraft edges, soft sage felt bases and pencil notes connect the humble boxes to Moku's miniature world. I'd lock the box footprint before modeling: the right-hand base box changes slightly between stages. The final model also needs an explicit mapping to the spec's 24 pieces.

**cast_lineup.png** — Built-in image generation, followed by a reference-guided edit; direction: Moku, Tetsu and Yuzu at matching companion scale in content poses, with names beneath on warm paper. The edit restored Tetsu's panel seams, smooth visor and chest marking order, and reduced loose fibres. The native banner is 1672 × 941 pixels, approximately 16:9 after pixel rounding. I'd further shorten Yuzu's surface fibres and soften its eyelids toward a clearer slow blink.

## Review (Claude, 2026-10-03): how to use these

These are **2D references only**, drawn by codex. The 3D is built by hand in Blender and checked render by render;
nothing here is copied blindly.
- `tetsu_character_sheet.png`: anatomy is right (two antennae, one visor, two eyes, TETSU-01). Use as the reference.
- `yuzu_character_sheet.png`: anatomy is right (two ears, one tail), but drawn as a realistic cat with visible fur.
  The 3D Yuzu takes Moku's plush proportions (a bigger head, a rounder body, short felt) so it reads at 120 pt and
  belongs on the same shelf.
- `tetsu_home_stages.png`, `yuzu_home_stages.png`: stage order and silhouettes are right; use as references.
- `cast_lineup.png`: **don't use where Moku shows.** Codex redrew Moku (its ears aren't Moku's asymmetric loop and
  flop, and the face differs). Any picture with Moku comes from the app's own renders.
