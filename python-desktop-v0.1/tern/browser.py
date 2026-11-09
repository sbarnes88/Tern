"""The Tern browser: a small desktop window that loads .tern pages.

Needs only Python's built-in tkinter. No JavaScript, no HTML engine.
Run:  python -m tern browse [file-or-url]
"""
import os
import sys
import urllib.parse
import urllib.request

from .lang import TernError, load

MAX_BYTES = 1_000_000


# --------------------------------------------------------------------------
# Loading (no GUI, easy to test)
# --------------------------------------------------------------------------
def resolve(base, target):
    """Turn a link target into a full location, relative to the current page."""
    if target.startswith(("http://", "https://", "file://")):
        return target
    if base.startswith(("http://", "https://")):
        return urllib.parse.urljoin(base, target)
    if os.path.isabs(target):
        return target
    return os.path.normpath(os.path.join(os.path.dirname(base) or ".", target))


def fetch(location):
    """Return the source text at a file path or http(s) URL."""
    if location.startswith(("http://", "https://")):
        req = urllib.request.Request(location, headers={"User-Agent": "TernBrowser/0.1"})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = r.read(MAX_BYTES + 1)
    else:
        path = location[7:] if location.startswith("file://") else location
        with open(path, "rb") as f:
            data = f.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise OSError("page is larger than 1 MB")
    return data.decode("utf-8")


def error_lines(err, src):
    """Human readable error report: message plus the offending source line."""
    lines = [f"{err.phase.title()}", str(err.msg)]
    line, col = err.pos
    rows = src.split("\n")
    if 1 <= line <= len(rows):
        lines += [f"line {line}:  {rows[line - 1].strip()}"]
    return lines


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------
def run(start):
    import tkinter as tk
    from tkinter import font as tkfont

    class Browser:
        def __init__(self):
            self.root = tk.Tk()
            self.root.geometry("820x640")
            self.root.title("Tern")
            self.history, self.pos = [], -1
            self.location, self.src, self.page = "", "", None

            bar = tk.Frame(self.root, padx=6, pady=6)
            bar.pack(fill="x")
            self.back_b = tk.Button(bar, text="◀", width=3, command=self.back)
            self.fwd_b = tk.Button(bar, text="▶", width=3, command=self.forward)
            self.rel_b = tk.Button(bar, text="↻", width=3, command=self.reload)
            for b in (self.back_b, self.fwd_b, self.rel_b):
                b.pack(side="left", padx=2)
            self.addr = tk.StringVar()
            e = tk.Entry(bar, textvariable=self.addr, font=("TkDefaultFont", 12))
            e.pack(side="left", fill="x", expand=True, padx=8)
            e.bind("<Return>", lambda _e: self.go(self.addr.get().strip()))

            self.status = tk.Label(self.root, anchor="w", padx=8, fg="#6e7781")
            self.status.pack(side="bottom", fill="x")

            holder = tk.Frame(self.root)
            holder.pack(fill="both", expand=True)
            self.canvas = tk.Canvas(holder, highlightthickness=0, bg="white")
            sb = tk.Scrollbar(holder, command=self.canvas.yview)
            self.canvas.configure(yscrollcommand=sb.set)
            sb.pack(side="right", fill="y")
            self.canvas.pack(side="left", fill="both", expand=True)
            self.body = tk.Frame(self.canvas, bg="white", padx=24, pady=20)
            self.win = self.canvas.create_window((0, 0), window=self.body, anchor="nw")
            self.body.bind("<Configure>", lambda _e: self.canvas.configure(
                scrollregion=self.canvas.bbox("all")))
            self.canvas.bind("<Configure>", self.on_resize)
            self.canvas.bind_all("<MouseWheel>", lambda e: self.canvas.yview_scroll(
                -1 if e.delta > 0 else 1, "units"))
            self.canvas.bind_all("<Button-4>", lambda _e: self.canvas.yview_scroll(-1, "units"))
            self.canvas.bind_all("<Button-5>", lambda _e: self.canvas.yview_scroll(1, "units"))
            self.f_head = tkfont.Font(size=24, weight="bold")
            self.f_link = tkfont.Font(underline=True)
            self.inputs = []
            self.go(start)

        # ---- navigation ----
        def go(self, target, push=True):
            location = resolve(self.location, target) if self.location else target
            self.addr.set(location)
            self.location = location
            if push:
                self.history = self.history[: self.pos + 1] + [location]
                self.pos = len(self.history) - 1
            self.open_current()

        def open_current(self):
            self.src, self.page = "", None
            try:
                self.src = fetch(self.location)
                self.page = load(self.src)
                self.root.title(f"{self.page.title} – Tern")
                self.status.config(text="", fg="#6e7781")
                self.show(self.page.render())
            except TernError as err:
                self.root.title("Error – Tern")
                self.show_error(error_lines(err, self.src))
            except (OSError, UnicodeDecodeError, ValueError) as err:
                self.root.title("Error – Tern")
                self.show_error(["Could not open page", str(err)])
            self.update_nav()

        def back(self):
            if self.pos > 0:
                self.pos -= 1
                self.location = self.history[self.pos]
                self.addr.set(self.location)
                self.open_current()

        def forward(self):
            if self.pos < len(self.history) - 1:
                self.pos += 1
                self.location = self.history[self.pos]
                self.addr.set(self.location)
                self.open_current()

        def reload(self):
            self.open_current()

        def update_nav(self):
            self.back_b.config(state="normal" if self.pos > 0 else "disabled")
            self.fwd_b.config(state="normal" if self.pos < len(self.history) - 1 else "disabled")

        # ---- drawing ----
        def on_resize(self, e):
            self.canvas.itemconfigure(self.win, width=e.width)
            self.wrap = max(e.width - 80, 200)

        def clear(self):
            for w in self.body.winfo_children():
                w.destroy()
            self.inputs = []

        def show_error(self, lines):
            self.clear()
            tk.Label(self.body, text=lines[0], font=self.f_head, fg="#b3261e",
                     bg="white").pack(anchor="w", pady=(0, 8))
            for ln in lines[1:]:
                tk.Label(self.body, text=ln, bg="white", justify="left", anchor="w",
                         wraplength=getattr(self, "wrap", 600),
                         font=("TkFixedFont", 11)).pack(anchor="w", pady=2)

        def show(self, nodes, focus=None):
            self.clear()
            self.build(nodes, self.body, vertical=True)
            if focus is not None and focus[0] < len(self.inputs):
                ent = self.inputs[focus[0]]
                ent.focus_set()
                ent.icursor(focus[1])

        def refresh(self, focus=None):
            try:
                self.show(self.page.render(), focus)
            except TernError as err:
                self.show_error(error_lines(err, self.src))

        def run_action(self, fn):
            try:
                fn()
                self.status.config(text="", fg="#6e7781")
            except TernError as err:
                self.status.config(text=str(err), fg="#b3261e")
            self.root.after_idle(self.refresh)

        def build(self, nodes, parent, vertical):
            side, anchor = ("top", "w") if vertical else ("left", "n")
            for n in nodes:
                t = n["t"]
                wrap = getattr(self, "wrap", 600)
                if t == "heading":
                    w = tk.Label(parent, text=n["text"], font=self.f_head, bg="white",
                                 justify="left", wraplength=wrap)
                elif t == "text":
                    w = tk.Label(parent, text=n["text"], bg="white", justify="left",
                                 wraplength=wrap, font=("TkDefaultFont", 12))
                elif t == "button":
                    w = tk.Button(parent, text=n["label"], padx=10, pady=3,
                                  command=lambda fn=n["click"]: self.run_action(fn))
                elif t == "input":
                    var = tk.StringVar(value=n["value"])
                    w = tk.Entry(parent, textvariable=var, width=34, font=("TkDefaultFont", 12))
                    idx = len(self.inputs)
                    self.inputs.append(w)
                    if not n["value"] and n["placeholder"]:
                        w.insert(0, n["placeholder"])
                        w.config(fg="#8c959f")
                        w.bind("<FocusIn>", lambda _e, w=w: (w.delete(0, "end"), w.config(fg="black"),
                                                              w.unbind("<FocusIn>")))
                    w.bind("<KeyRelease>", lambda _e, w=w, n=n, idx=idx: self.on_type(w, n, idx))
                elif t == "link":
                    w = tk.Label(parent, text=n["text"], fg="#0b57d0", bg="white",
                                 font=self.f_link, cursor="hand2")
                    w.bind("<Button-1>", lambda _e, tg=n["target"]: self.go(tg))
                elif t == "divider":
                    w = tk.Frame(parent, height=1, bg="#d0d7de")
                    w.pack(side=side, fill="x", pady=8)
                    continue
                else:  # row / column
                    w = tk.Frame(parent, bg="white")
                    self.build(n["children"], w, t == "column")
                w.pack(side=side, anchor=anchor, pady=4, padx=(0, 8) if not vertical else 0)

        def on_type(self, entry, node, idx):
            try:
                node["set"](entry.get())
            except TernError as err:
                self.status.config(text=str(err), fg="#b3261e")
            cursor = entry.index("insert")
            self.root.after_idle(lambda: self.refresh((idx, cursor)))

    Browser().root.mainloop()


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "examples/home.tern")
