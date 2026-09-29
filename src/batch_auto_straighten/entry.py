"""Entry point for the relocatable, bundled image-analysis executable."""
from pathlib import Path
import sys
sys.dont_write_bytecode = True

# Native dependencies are collected with PyInstaller hidden imports.
# Runtime imports happen inside analyze(), after its process deadline is armed.


def main():
    bundle = Path(sys.executable).resolve().parents[2]
    sys.path.insert(0, str(bundle / 'python'))
    from batch_auto_straighten.image_analysis_helper import main as analyze
    sys.argv[1:1] = ['--bundle', str(bundle)]
    analyze()


if __name__ == '__main__':
    main()
