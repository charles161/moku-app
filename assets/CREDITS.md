# How the art was made

- **The 3D art is made in-house, in code.** The Blender and Python scripts in `assets/src` build the companions, their
  faces, moods and animations, the houses, the props, the icons and the symbols (`assets/src/rebuild.sh` runs them,
  with Blender's Python API). The app's own renderer makes the pictures and clips of the companions on the website.
- **The concept art was made with OpenAI's image tool.** `assets/concept/*.png` were generated from the prompts in
  `assets/src/concept-prompts.json` (Moku's sheets) and the directions in `assets/concept/friends-notes.md` (the other
  companions' sheets and the line-up), and `assets/src/felt_source.png` (the source of the felt texture) from
  `assets/src/felt-prompt.txt`. They are 2D references only; the 3D models are built by the scripts above.
- **Fonts** on the website: DM Sans and Instrument Serif, under the SIL Open Font License 1.1 (see `/NOTICE`).

All of the art is under `assets/LICENSE-ASSETS.md`.
