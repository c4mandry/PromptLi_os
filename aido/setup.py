"""Package installer for AIDO (terminal edition).

Installs the flat src/ modules as top-level Python modules and provides the
``aido`` console command. The GUI/tray/voice frontends were removed — AIDO is
terminal-only on promptLi OS (a headless, server-focused system).

Light install:  pip install .          (PyYAML + requests only)
Full LLM:       pip install .[llm]     (+ llama-cpp-python)
Browser tools:  pip install .[web]     (+ playwright)
Development:    pip install -e ".[dev]"
"""

from pathlib import Path

from setuptools import setup

README = Path(__file__).parent / "README.md"

setup(
    name="aido",
    version="0.2.0",
    description="AIDO — AI Desktop Operator: a local, private, terminal-first assistant for Linux.",
    long_description=README.read_text(encoding="utf-8") if README.is_file() else "",
    long_description_content_type="text/markdown",
    author="AIDO Contributors",
    license="MIT",
    package_dir={"": "src"},
    py_modules=["aido", "agent", "tools", "utils"],
    python_requires=">=3.10",
    install_requires=[
        "PyYAML>=6.0.1",
        "requests>=2.31.0",
    ],
    extras_require={
        "dev": ["pytest>=8.0", "ruff>=0.9"],
        "llm": ["llama-cpp-python>=0.3.2"],
        "web": ["playwright>=1.44.0"],
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
