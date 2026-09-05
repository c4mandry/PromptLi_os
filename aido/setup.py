"""Package installer for AIDO (MVP).

Installs the flat src/ modules as top-level Python modules and provides the
``aido`` console command. Development dependencies: pip install -e ".[dev]"
"""

from pathlib import Path

from setuptools import setup

README = Path(__file__).parent / "README.md"

setup(
    name="aido",
    version="0.1.0",
    description="AIDO — AI Desktop Operator: a local, open-source desktop assistant for Linux.",
    long_description=README.read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
    author="AIDO Contributors",
    url="https://github.com/aido/aido",
    license="MIT",
    package_dir={"": "src"},
    py_modules=["aido", "agent", "gui", "tools", "tray", "utils", "voice"],
    python_requires=">=3.10",
    install_requires=[
        "llama-cpp-python>=0.3.2",
        "playwright>=1.44.0",
        "PyYAML>=6.0.1",
        "requests>=2.31.0",
    ],
    extras_require={
        "dev": ["pytest>=8.0", "ruff>=0.9"],
        "voice": ["SpeechRecognition>=3.10", "pocketsphinx>=5.0"],
        "tray": ["pystray>=0.19", "Pillow>=10.0"],
    },
    entry_points={"console_scripts": ["aido=aido:main"]},
    classifiers=[
        "Development Status :: 4 - Beta",
        "Environment :: Console",
        "Intended Audience :: End Users/Desktop",
        "Operating System :: POSIX :: Linux",
        "Programming Language :: Python :: 3",
        "Topic :: Desktop Environment",
    ],
)
