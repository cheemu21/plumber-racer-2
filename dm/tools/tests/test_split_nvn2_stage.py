"""shader_split: an NVN2 record's stage comes from the control section's stage byte (+0x56: 5 compute, 6 task, 7 mesh), except that a compute byte over a code area that starts with a shader
program header is the graphics shader the header says (Mario Kart World 1.8.0's DrivePassShaderDefault: a vertex shader under a compute control, whose SPH was decoded as instruction 0x481).
No game files needed."""
import os
import struct
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
_had = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = '010029B0118E8000'   # shader_split loads a profile at import; other tests expect no default game
import shader_split as ss
if _had is None: del os.environ['DM_GAME']
else: os.environ['DM_GAME'] = _had


def ctl(stage_byte):   # an NVN2 control section: the magic, version 0xc9, the stage byte at +0x56
    c = bytearray(0xd8); c[:4] = ss.CTL_MAGIC; c[4:8] = b'\xc9\0\0\0'; c[0x56] = stage_byte; return bytes(c)

SPH_VERTEX = struct.pack('<IIII', 0x020c0481, 0, 0, 0) + bytes(0x70)   # SPH word 0 as the game writes it: type 1 VTG, version 4, shader type 1 vertex; the second quadword zero
SPH_DOMAIN = struct.pack('<IIII', 0x020c0c81, 0, 0, 0) + bytes(0x70)   # shader type 3: what a mesh shader's SPH says
INSTRUCTION = struct.pack('<QQ', 0x7919, 0x000fc40000000000)           # S2R with predicate PT and its scheduling control: how every compute program starts


class Nvn2Stage(unittest.TestCase):
    def test_compute_byte_over_an_instruction_is_compute(self):
        self.assertEqual(ss.nvn2_stage(ctl(5), INSTRUCTION + bytes(0x100)), 'cs')

    def test_compute_byte_over_a_vertex_sph_is_the_vertex_shader(self):
        self.assertEqual(ss.nvn2_stage(ctl(5), SPH_VERTEX + INSTRUCTION), 'vs')

    def test_task_and_mesh_keep_their_stage_byte_over_an_sph(self):
        self.assertEqual(ss.nvn2_stage(ctl(6), SPH_VERTEX + INSTRUCTION), 'ts')
        self.assertEqual(ss.nvn2_stage(ctl(7), SPH_DOMAIN + INSTRUCTION), 'ms')

    def test_graphics_without_a_stage_byte_reads_the_sph(self):
        self.assertEqual(ss.nvn2_stage(ctl(0), SPH_VERTEX + INSTRUCTION), 'vs')
        self.assertEqual(ss.nvn2_stage(ctl(1), struct.pack('<IIII', 0x020c1482, 0, 0, 0) + bytes(0x70)), 'ps')   # type 2 PS, shader type 5


if __name__ == '__main__': unittest.main()
