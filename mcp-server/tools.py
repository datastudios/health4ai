"""Compatibility shim so clone-layout `import tools` still resolves.

Replaces this module object with `health4ai.tools` so `importlib.reload(tools)`
(used by timezone tests) reloads the real implementation.
"""

import sys

from health4ai import tools as _tools

sys.modules[__name__] = _tools
