"""Builds a companion: the shared rig, morph names and export (companion.py) around its species module
(species_moku.py, species_tetsu.py). Run in Blender 5.2.1:

  Blender --background --factory-startup --python assets/src/character.py -- [--companion=tetsu] [--quick]

Moku when no companion is given, writing character/moku_bunny.usdz exactly as before the split.
"""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from companion import build,species
build(species())
