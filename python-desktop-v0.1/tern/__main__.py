"""Command line:  python -m tern <command> <file>

  browse [file-or-url]   open the desktop browser
  check  <file>          type-check a page and report errors
  text   <file>          print the page as plain text
  png    <file> <out>    render the page to a PNG (no display needed)
"""
import os
import sys

from .lang import TernError, load, render_text
from .browser import error_lines

USAGE = __doc__


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "browse":
        from .browser import run
        run(rest[0] if rest else os.path.join(os.path.dirname(__file__), "..", "examples", "home.tern"))
        return 0
    if cmd in ("check", "text", "png") and rest:
        with open(rest[0], encoding="utf-8") as f:
            src = f.read()
        try:
            page = load(src)
        except TernError as err:
            if cmd == "png" and len(rest) > 1:
                from .png import render_png
                render_png([], rest[1], "Error", rest[0], error_lines=error_lines(err, src))
            print(err, file=sys.stderr)
            return 1
        if cmd == "check":
            print(f"ok: '{page.title}' type-checks")
        elif cmd == "text":
            print("\n".join(render_text(page.render())))
        elif len(rest) > 1:
            from .png import render_png
            print(render_png(page.render(), rest[1], page.title, rest[0]))
        else:
            print(USAGE)
            return 2
        return 0
    print(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
