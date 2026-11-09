"""Tern: a small, strongly typed language for describing web pages.

Pipeline:  source -> tokens -> AST -> type check -> runtime -> render tree

Every page is checked *before* it runs. A page with a type error never
renders; the browser shows the error with its line and column instead.
"""
import re


class TernError(Exception):
    def __init__(self, msg, pos=(0, 0), phase="error"):
        super().__init__(msg)
        self.msg, self.pos, self.phase = msg, pos, phase

    def __str__(self):
        line, col = self.pos
        return f"{self.phase} at line {line}, column {col}: {self.msg}"


# --------------------------------------------------------------------------
# Types:  "Int" | "Text" | "Bool" | "Unit" | ("List", elem_type)
# --------------------------------------------------------------------------
INT, TEXT, BOOL, UNIT = "Int", "Text", "Bool", "Unit"


def tname(t):
    return t if isinstance(t, str) else f"List<{tname(t[1])}>"


def is_list(t):
    return isinstance(t, tuple)


# --------------------------------------------------------------------------
# Lexer
# --------------------------------------------------------------------------
KEYWORDS = {
    "page", "state", "fn", "view", "let", "if", "else", "for", "in",
    "return", "true", "false", "to", "placeholder",
    # view elements
    "text", "heading", "button", "input", "row", "column", "link", "divider",
}

TOKEN_RE = re.compile(
    r"""
    (?P<ws>[ \t\r]+) | (?P<nl>\n) | (?P<comment>//[^\n]*) |
    (?P<int>\d+) | (?P<str>"(?:[^"\\\n]|\\.)*") |
    (?P<id>[A-Za-z_][A-Za-z0-9_]*) |
    (?P<op>->|==|!=|<=|>=|&&|\|\||[{}()\[\],:=<>+\-*/%!])
    """,
    re.X,
)
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}


class Tok:
    __slots__ = ("kind", "val", "pos")

    def __init__(self, kind, val, pos):
        self.kind, self.val, self.pos = kind, val, pos


def tokenize(src):
    toks, i, line, ls = [], 0, 1, 0
    while i < len(src):
        m = TOKEN_RE.match(src, i)
        pos = (line, i - ls + 1)
        if not m:
            if src[i] == '"':
                raise TernError("unterminated string", pos, "syntax error")
            raise TernError(f"unexpected character {src[i]!r}", pos, "syntax error")
        kind, text = m.lastgroup, m.group()
        i = m.end()
        if kind == "nl":
            line, ls = line + 1, i
        elif kind in ("ws", "comment"):
            pass
        elif kind == "int":
            toks.append(Tok("int", int(text), pos))
        elif kind == "str":
            body, out, j = text[1:-1], [], 0
            while j < len(body):
                if body[j] == "\\":
                    c = body[j + 1]
                    if c not in ESCAPES:
                        raise TernError(f"unknown escape \\{c}", pos, "syntax error")
                    out.append(ESCAPES[c])
                    j += 2
                else:
                    out.append(body[j])
                    j += 1
            toks.append(Tok("str", "".join(out), pos))
        elif kind == "id":
            toks.append(Tok("kw" if text in KEYWORDS else "id", text, pos))
        else:
            toks.append(Tok("op", text, pos))
    toks.append(Tok("eof", "end of file", (line, i - ls + 1)))
    return toks


# --------------------------------------------------------------------------
# AST + parser
# --------------------------------------------------------------------------
class N:
    """Generic AST node: N('bin', pos, op='+', l=..., r=...)"""

    def __init__(self, kind, pos, **kw):
        self.kind, self.pos = kind, pos
        self.__dict__.update(kw)


BIN_LEVELS = [["||"], ["&&"], ["==", "!="], ["<", ">", "<=", ">="], ["+", "-"], ["*", "/", "%"]]
BASE_TYPES = {"Int": INT, "Text": TEXT, "Bool": BOOL}


class Parser:
    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self, k=0):
        return self.t[min(self.i + k, len(self.t) - 1)]

    def next(self):
        tok = self.peek()
        self.i += 1
        return tok

    def is_(self, val, k=0):
        tok = self.peek(k)
        return tok.kind in ("kw", "op") and tok.val == val

    def accept(self, val):
        if self.is_(val):
            return self.next()
        return None

    def expect(self, val):
        if not self.is_(val):
            tok = self.peek()
            raise TernError(f"expected '{val}' but found '{tok.val}'", tok.pos, "syntax error")
        return self.next()

    def ident(self, what="a name"):
        tok = self.peek()
        if tok.kind != "id":
            raise TernError(f"expected {what} but found '{tok.val}'", tok.pos, "syntax error")
        return self.next()

    # ---- program ----
    def program(self):
        title, states, fns, view = None, [], [], None
        if self.accept("page"):
            title = self.next_kind("str", "a page title in quotes").val
        while self.peek().kind != "eof":
            tok = self.peek()
            if self.is_("state"):
                states.append(self.state_decl())
            elif self.is_("fn"):
                fns.append(self.fn_decl())
            elif self.is_("view"):
                if view is not None:
                    raise TernError("a page can only have one view", tok.pos, "syntax error")
                self.next()
                view = self.view_block()
            else:
                raise TernError(f"expected 'state', 'fn' or 'view' but found '{tok.val}'",
                                tok.pos, "syntax error")
        if view is None:
            raise TernError("page has no view", self.peek().pos, "syntax error")
        return N("program", (1, 1), title=title, states=states, fns=fns, view=view)

    def next_kind(self, kind, what):
        tok = self.peek()
        if tok.kind != kind:
            raise TernError(f"expected {what} but found '{tok.val}'", tok.pos, "syntax error")
        return self.next()

    def type_(self):
        tok = self.ident("a type")
        if tok.val in BASE_TYPES:
            return BASE_TYPES[tok.val]
        if tok.val == "List":
            self.expect("<")
            inner = self.type_()
            self.expect(">")
            return ("List", inner)
        raise TernError(f"unknown type '{tok.val}' (try Int, Text, Bool or List<...>)",
                        tok.pos, "syntax error")

    def state_decl(self):
        pos = self.next().pos
        name = self.ident("a state name").val
        self.expect(":")
        ty = self.type_()
        self.expect("=")
        return N("state", pos, name=name, type=ty, init=self.expr())

    def fn_decl(self):
        pos = self.next().pos
        name = self.ident("a function name").val
        self.expect("(")
        params = []
        while not self.is_(")"):
            ptok = self.ident("a parameter name")
            self.expect(":")
            params.append((ptok.val, self.type_(), ptok.pos))
            if not self.accept(","):
                break
        self.expect(")")
        ret = self.type_() if self.accept(":") else UNIT
        return N("fn", pos, name=name, params=params, ret=ret, body=self.block())

    # ---- statements ----
    def block(self):
        self.expect("{")
        out = []
        while not self.is_("}"):
            if self.peek().kind == "eof":
                raise TernError("missing '}'", self.peek().pos, "syntax error")
            out.append(self.stmt())
        self.expect("}")
        return out

    def stmt(self):
        tok = self.peek()
        if self.accept("let"):
            name = self.ident("a variable name").val
            ty = self.type_() if self.accept(":") else None
            self.expect("=")
            return N("let", tok.pos, name=name, type=ty, value=self.expr())
        if self.accept("if"):
            cond, then, other = self.expr(), self.block(), []
            if self.accept("else"):
                other = [self.stmt()] if self.is_("if") else self.block()
            return N("if", tok.pos, cond=cond, then=then, other=other)
        if self.accept("for"):
            var = self.ident("a loop variable").val
            self.expect("in")
            return N("for", tok.pos, var=var, iter=self.expr(), body=self.block())
        if self.accept("return"):
            if self.is_("}"):
                return N("return", tok.pos, value=None)
            return N("return", tok.pos, value=self.expr())
        if tok.kind == "id" and self.is_("=", 1):
            self.next()
            self.next()
            return N("assign", tok.pos, name=tok.val, value=self.expr())
        return N("expr", tok.pos, value=self.expr())

    # ---- expressions ----
    def expr(self, lvl=0):
        if lvl == len(BIN_LEVELS):
            return self.unary()
        left = self.expr(lvl + 1)
        while self.peek().kind == "op" and self.peek().val in BIN_LEVELS[lvl]:
            op = self.next()
            left = N("bin", op.pos, op=op.val, l=left, r=self.expr(lvl + 1))
        return left

    def unary(self):
        tok = self.peek()
        if tok.kind == "op" and tok.val in ("!", "-"):
            self.next()
            return N("un", tok.pos, op=tok.val, e=self.unary())
        return self.postfix()

    def postfix(self):
        e = self.primary()
        while True:
            if self.is_("(") and e.kind == "var":
                pos = self.next().pos
                args = []
                while not self.is_(")"):
                    args.append(self.expr())
                    if not self.accept(","):
                        break
                self.expect(")")
                e = N("call", e.pos, name=e.name, args=args)
            elif self.is_("["):
                pos = self.next().pos
                idx = self.expr()
                self.expect("]")
                e = N("index", pos, e=e, idx=idx)
            else:
                return e

    def primary(self):
        tok = self.next()
        if tok.kind == "int":
            return N("int", tok.pos, v=tok.val)
        if tok.kind == "str":
            return N("str", tok.pos, v=tok.val)
        if tok.kind == "id":
            return N("var", tok.pos, name=tok.val)
        if tok.kind == "kw" and tok.val in ("true", "false"):
            return N("bool", tok.pos, v=tok.val == "true")
        if tok.kind == "op" and tok.val == "[":
            items = []
            while not self.is_("]"):
                items.append(self.expr())
                if not self.accept(","):
                    break
            self.expect("]")
            return N("list", tok.pos, items=items)
        if tok.kind == "op" and tok.val == "(":
            e = self.expr()
            self.expect(")")
            return e
        raise TernError(f"expected an expression but found '{tok.val}'", tok.pos, "syntax error")

    # ---- view ----
    def view_block(self):
        self.expect("{")
        out = []
        while not self.is_("}"):
            if self.peek().kind == "eof":
                raise TernError("missing '}'", self.peek().pos, "syntax error")
            out.append(self.view_item())
        self.expect("}")
        return out

    def view_item(self):
        tok = self.next()
        k = tok.val if tok.kind == "kw" else None
        if k in ("heading", "text"):
            return N(k, tok.pos, e=self.expr())
        if k == "button":
            label = self.expr()
            self.expect("->")
            action = self.block() if self.is_("{") else [self.stmt()]
            return N("button", tok.pos, label=label, action=action)
        if k == "input":
            name = self.ident("the name of a Text state").val
            ph = self.expr() if self.accept("placeholder") else None
            return N("input", tok.pos, name=name, placeholder=ph)
        if k in ("row", "column"):
            return N(k, tok.pos, body=self.view_block())
        if k == "if":
            cond, then, other = self.expr(), self.view_block(), []
            if self.accept("else"):
                other = [self.view_item()] if self.is_("if") else self.view_block()
            return N("vif", tok.pos, cond=cond, then=then, other=other)
        if k == "for":
            var = self.ident("a loop variable").val
            self.expect("in")
            return N("vfor", tok.pos, var=var, iter=self.expr(), body=self.view_block())
        if k == "link":
            label = self.expr()
            self.expect("to")
            return N("link", tok.pos, label=label, target=self.expr())
        if k == "divider":
            return N("divider", tok.pos)
        raise TernError(f"expected a view element (text, heading, button, ...) but found '{tok.val}'",
                        tok.pos, "syntax error")


def parse(src):
    return Parser(tokenize(src)).program()


# --------------------------------------------------------------------------
# Type checker
# --------------------------------------------------------------------------
def always_returns(stmts):
    for s in stmts:
        if s.kind == "return":
            return True
        if s.kind == "if" and s.other and always_returns(s.then) and always_returns(s.other):
            return True
    return False


class Checker:
    def __init__(self, prog):
        self.prog = prog
        self.states = {}
        self.fns = {}
        self.scopes = []
        self.ret = None  # return type of the function being checked (None = not in a function)

    def err(self, msg, node):
        raise TernError(msg, node.pos, "type error")

    # ---- scopes ----
    def lookup(self, name):
        for sc in reversed(self.scopes):
            if name in sc:
                return sc[name]
        return self.states.get(name)

    def declare(self, name, ty, node):
        if name in self.scopes[-1]:
            self.err(f"'{name}' is already defined here", node)
        self.scopes[-1][name] = ty

    # ---- entry ----
    def run(self):
        p = self.prog
        for s in p.states:
            if s.name in self.states or s.name in self.fns:
                self.err(f"'{s.name}' is defined twice", s)
            self.states[s.name] = s.type
        for f in p.fns:
            if f.name in self.states or f.name in self.fns or f.name in BUILTINS:
                self.err(f"'{f.name}' is defined twice or is a built-in name", f)
            self.fns[f.name] = ([t for _, t, _ in f.params], f.ret)
        self.scopes = [{}]
        for s in p.states:
            self.expect_type(s.init, s.type, f"state '{s.name}'")
        for f in p.fns:
            self.scopes = [{}]
            for name, ty, pos in f.params:
                self.declare(name, ty, N("p", pos))
            self.ret = f.ret
            self.block(f.body)
            if f.ret != UNIT and not always_returns(f.body):
                self.err(f"function '{f.name}' must return {tname(f.ret)} on every path", f)
        self.ret = None
        self.scopes = [{}]
        self.view(p.view)
        return self

    # ---- statements ----
    def block(self, stmts):
        self.scopes.append({})
        for s in stmts:
            self.stmt(s)
        self.scopes.pop()

    def stmt(self, s):
        k = s.kind
        if k == "let":
            if s.type is not None:
                self.expect_type(s.value, s.type, f"'{s.name}'")
                ty = s.type
            else:
                ty = self.expr(s.value)
            self.declare(s.name, ty, s)
        elif k == "assign":
            ty = self.lookup(s.name)
            if ty is None:
                self.err(f"unknown variable '{s.name}'", s)
            self.expect_type(s.value, ty, f"'{s.name}'")
        elif k == "if":
            self.expect_type(s.cond, BOOL, "an if condition")
            self.block(s.then)
            self.block(s.other)
        elif k == "for":
            ity = self.expr(s.iter)
            if not is_list(ity):
                self.err(f"can only loop over a List, not {tname(ity)}", s.iter)
            self.scopes.append({s.var: ity[1]})
            self.block(s.body)
            self.scopes.pop()
        elif k == "return":
            if self.ret is None:
                self.err("'return' can only be used inside a function", s)
            if s.value is None:
                if self.ret != UNIT:
                    self.err(f"this function must return {tname(self.ret)}", s)
            else:
                self.expect_type(s.value, self.ret, "the returned value")
        elif k == "expr":
            if s.value.kind != "call":
                self.err("this expression does nothing; use a call or an assignment", s)
            self.expr(s.value)

    # ---- expressions ----
    def expect_type(self, e, want, what):
        got = self.expr(e, want)
        if got != want:
            hint = ""
            if want == TEXT and got in (INT, BOOL):
                hint = f" (use toText(...) to convert {tname(got)} to Text)"
            self.err(f"{what} needs {tname(want)} but this is {tname(got)}{hint}", e)

    def expr(self, e, expected=None):
        k = e.kind
        if k == "int":
            return INT
        if k == "str":
            return TEXT
        if k == "bool":
            return BOOL
        if k == "var":
            ty = self.lookup(e.name)
            if ty is None:
                if e.name in self.fns or e.name in BUILTINS:
                    self.err(f"'{e.name}' is a function; call it like {e.name}(...)", e)
                self.err(f"unknown name '{e.name}'", e)
            return ty
        if k == "list":
            if not e.items:
                if is_list(expected):
                    return expected
                self.err("cannot tell what an empty list holds; add a type, e.g. let xs: List<Int> = []", e)
            first = self.expr(e.items[0], expected[1] if is_list(expected) else None)
            for it in e.items[1:]:
                self.expect_type(it, first, "every list item")
            return ("List", first)
        if k == "un":
            if e.op == "!":
                self.expect_type(e.e, BOOL, "'!'")
                return BOOL
            self.expect_type(e.e, INT, "unary '-'")
            return INT
        if k == "bin":
            return self.binary(e)
        if k == "index":
            lt = self.expr(e.e)
            if not is_list(lt):
                self.err(f"can only index a List, not {tname(lt)}", e)
            self.expect_type(e.idx, INT, "a list index")
            return lt[1]
        if k == "call":
            return self.call(e, expected)
        raise AssertionError(k)

    def binary(self, e):
        op = e.op
        if op in ("&&", "||"):
            self.expect_type(e.l, BOOL, f"'{op}'")
            self.expect_type(e.r, BOOL, f"'{op}'")
            return BOOL
        lt, rt = self.expr(e.l), self.expr(e.r)
        if op in ("==", "!="):
            if lt != rt:
                self.err(f"cannot compare {tname(lt)} with {tname(rt)}", e)
            return BOOL
        if op == "+" and lt == TEXT and rt == TEXT:
            return TEXT
        if op == "+" and is_list(lt) and lt == rt:
            return lt
        if lt != INT or rt != INT:
            hint = " (use toText(...) to join numbers into Text)" if op == "+" and TEXT in (lt, rt) else ""
            self.err(f"'{op}' cannot be used on {tname(lt)} and {tname(rt)}{hint}", e)
        return BOOL if op in ("<", ">", "<=", ">=") else INT

    def call(self, e, expected):
        name = e.name
        if name in self.fns:
            params, ret = self.fns[name]
            if len(e.args) != len(params):
                self.err(f"{name}() takes {len(params)} argument(s) but got {len(e.args)}", e)
            for a, pt in zip(e.args, params):
                self.expect_type(a, pt, f"an argument of {name}()")
            return ret
        if name in BUILTINS:
            return self.builtin(e, expected)
        self.err(f"unknown function '{name}'", e)

    def builtin(self, e, expected):
        name, args = e.name, e.args
        sig_n = BUILTINS[name]
        if len(args) != sig_n:
            self.err(f"{name}() takes {sig_n} argument(s) but got {len(args)}", e)
        if name == "toText":
            t = self.expr(args[0])
            if t not in (INT, BOOL, TEXT):
                self.err(f"toText() works on Int, Bool and Text, not {tname(t)}", e)
            return TEXT
        if name == "len":
            t = self.expr(args[0])
            if t != TEXT and not is_list(t):
                self.err(f"len() works on Text and List, not {tname(t)}", e)
            return INT
        if name == "append":
            lt = self.expr(args[0], expected)
            if not is_list(lt):
                self.err(f"append() needs a List first, not {tname(lt)}", args[0])
            self.expect_type(args[1], lt[1], "the appended item")
            return lt
        if name == "removeAt":
            lt = self.expr(args[0])
            if not is_list(lt):
                self.err(f"removeAt() needs a List first, not {tname(lt)}", args[0])
            self.expect_type(args[1], INT, "the index")
            return lt
        if name == "range":
            self.expect_type(args[0], INT, "range()")
            return ("List", INT)
        if name in ("trim", "upper", "lower"):
            self.expect_type(args[0], TEXT, f"{name}()")
            return TEXT
        if name == "contains":
            self.expect_type(args[0], TEXT, "contains()")
            self.expect_type(args[1], TEXT, "contains()")
            return BOOL
        if name == "join":
            self.expect_type(args[0], ("List", TEXT), "join()")
            self.expect_type(args[1], TEXT, "join()")
            return TEXT
        raise AssertionError(name)

    # ---- view ----
    def view(self, items):
        for it in items:
            k = it.kind
            if k in ("heading", "text"):
                self.expect_type(it.e, TEXT, f"'{k}'")
            elif k == "button":
                self.expect_type(it.label, TEXT, "a button label")
                self.ret = None
                self.block(it.action)
            elif k == "input":
                ty = self.states.get(it.name)
                if ty is None:
                    self.err(f"'{it.name}' is not a state; declare it with: state {it.name}: Text = \"\"", it)
                if ty != TEXT:
                    self.err(f"input can only edit Text state, but '{it.name}' is {tname(ty)}", it)
                if it.placeholder is not None:
                    self.expect_type(it.placeholder, TEXT, "a placeholder")
            elif k in ("row", "column"):
                self.view(it.body)
            elif k == "vif":
                self.expect_type(it.cond, BOOL, "an if condition")
                self.scoped_view(it.then)
                self.scoped_view(it.other)
            elif k == "vfor":
                ity = self.expr(it.iter)
                if not is_list(ity):
                    self.err(f"can only loop over a List, not {tname(ity)}", it.iter)
                self.scopes.append({it.var: ity[1]})
                self.view(it.body)
                self.scopes.pop()
            elif k == "link":
                self.expect_type(it.label, TEXT, "a link label")
                self.expect_type(it.target, TEXT, "a link target")

    def scoped_view(self, items):
        self.scopes.append({})
        self.view(items)
        self.scopes.pop()


BUILTINS = {
    "toText": 1, "len": 1, "append": 2, "removeAt": 2, "range": 1,
    "trim": 1, "upper": 1, "lower": 1, "contains": 2, "join": 2,
}


def check(prog):
    return Checker(prog).run()


# --------------------------------------------------------------------------
# Runtime
# --------------------------------------------------------------------------
class _Return(Exception):
    def __init__(self, value):
        self.value = value


class Page:
    """A checked page plus its live state. Call render() after any change."""

    def __init__(self, src):
        self.prog = parse(src)
        check(self.prog)
        self.title = self.prog.title or "Untitled"
        self.fns = {f.name: f for f in self.prog.fns}
        self.state = {}
        for s in self.prog.states:
            self.state[s.name] = self.eval(s.init, [{}])

    # ---- statements ----
    def exec_block(self, stmts, scopes):
        scopes.append({})
        try:
            for s in stmts:
                self.exec(s, scopes)
        finally:
            scopes.pop()

    def exec(self, s, scopes):
        k = s.kind
        if k == "let":
            scopes[-1][s.name] = self.eval(s.value, scopes)
        elif k == "assign":
            v = self.eval(s.value, scopes)
            for sc in reversed(scopes):
                if s.name in sc:
                    sc[s.name] = v
                    return
            self.state[s.name] = v
        elif k == "if":
            self.exec_block(s.then if self.eval(s.cond, scopes) else s.other, scopes)
        elif k == "for":
            for item in list(self.eval(s.iter, scopes)):
                scopes.append({s.var: item})
                try:
                    self.exec_block(s.body, scopes)
                finally:
                    scopes.pop()
        elif k == "return":
            raise _Return(None if s.value is None else self.eval(s.value, scopes))
        elif k == "expr":
            self.eval(s.value, scopes)

    # ---- expressions ----
    def lookup(self, name, scopes):
        for sc in reversed(scopes):
            if name in sc:
                return sc[name]
        return self.state[name]

    def rt_err(self, msg, node):
        raise TernError(msg, node.pos, "runtime error")

    def eval(self, e, scopes):
        k = e.kind
        if k in ("int", "str", "bool"):
            return e.v
        if k == "var":
            return self.lookup(e.name, scopes)
        if k == "list":
            return [self.eval(i, scopes) for i in e.items]
        if k == "un":
            v = self.eval(e.e, scopes)
            return (not v) if e.op == "!" else -v
        if k == "index":
            lst, i = self.eval(e.e, scopes), self.eval(e.idx, scopes)
            if not 0 <= i < len(lst):
                self.rt_err(f"index {i} is outside the list (length {len(lst)})", e)
            return lst[i]
        if k == "bin":
            return self.binop(e, scopes)
        if k == "call":
            return self.call(e, scopes)
        raise AssertionError(k)

    def binop(self, e, scopes):
        op = e.op
        if op == "&&":
            return self.eval(e.l, scopes) and self.eval(e.r, scopes)
        if op == "||":
            return self.eval(e.l, scopes) or self.eval(e.r, scopes)
        a, b = self.eval(e.l, scopes), self.eval(e.r, scopes)
        if op == "+":
            return a + b
        if op == "-":
            return a - b
        if op == "*":
            return a * b
        if op in ("/", "%"):
            if b == 0:
                self.rt_err("division by zero", e)
            return a // b if op == "/" else a % b
        return {"==": a == b, "!=": a != b, "<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]

    def call(self, e, scopes):
        args = [self.eval(a, scopes) for a in e.args]
        name = e.name
        if name in self.fns:
            f = self.fns[name]
            frame = [{}, {p[0]: v for p, v in zip(f.params, args)}]
            try:
                self.exec_block(f.body, frame)
            except _Return as r:
                return r.value
            except RecursionError:
                self.rt_err(f"{name}() recursed too deeply", e)
            return None
        if name == "toText":
            v = args[0]
            return ("true" if v else "false") if isinstance(v, bool) else str(v)
        if name == "len":
            return len(args[0])
        if name == "append":
            return args[0] + [args[1]]
        if name == "removeAt":
            if not 0 <= args[1] < len(args[0]):
                self.rt_err(f"index {args[1]} is outside the list (length {len(args[0])})", e)
            return args[0][:args[1]] + args[0][args[1] + 1:]
        if name == "range":
            return list(range(min(max(args[0], 0), 10000)))
        if name == "trim":
            return args[0].strip()
        if name == "upper":
            return args[0].upper()
        if name == "lower":
            return args[0].lower()
        if name == "contains":
            return args[1] in args[0]
        if name == "join":
            return args[1].join(args[0])
        raise AssertionError(name)

    # ---- rendering ----
    def render(self):
        """Evaluate the view with the current state into a plain tree of dicts."""
        out = []
        self._view(self.prog.view, [{}], out)
        return out

    def _view(self, items, scopes, out):
        for it in items:
            k = it.kind
            if k in ("heading", "text"):
                out.append({"t": k, "text": self.eval(it.e, scopes)})
            elif k == "button":
                snap = [dict(s) for s in scopes]
                out.append({"t": "button", "label": self.eval(it.label, scopes),
                            "click": lambda it=it, snap=snap: self.exec_block(it.action, snap)})
            elif k == "input":
                name = it.name
                out.append({
                    "t": "input", "name": name, "value": self.state[name],
                    "placeholder": self.eval(it.placeholder, scopes) if it.placeholder else "",
                    "set": lambda v, name=name: self.state.__setitem__(name, v),
                })
            elif k in ("row", "column"):
                kids = []
                self._view(it.body, scopes, kids)
                out.append({"t": k, "children": kids})
            elif k == "vif":
                self._view(it.then if self.eval(it.cond, scopes) else it.other, scopes, out)
            elif k == "vfor":
                for item in list(self.eval(it.iter, scopes)):
                    scopes.append({it.var: item})
                    try:
                        self._view(it.body, scopes, out)
                    finally:
                        scopes.pop()
            elif k == "link":
                out.append({"t": "link", "text": self.eval(it.label, scopes),
                            "target": self.eval(it.target, scopes)})
            elif k == "divider":
                out.append({"t": "divider"})


def load(src):
    """Parse + type-check + initialise a page. Raises TernError on any problem."""
    return Page(src)


# --------------------------------------------------------------------------
# Plain-text renderer (used by tests and `tern --text`)
# --------------------------------------------------------------------------
def render_text(nodes, indent=0):
    pad = "  " * indent
    lines = []
    for n in nodes:
        t = n["t"]
        if t == "heading":
            lines += [pad + n["text"].upper(), pad + "=" * max(len(n["text"]), 3)]
        elif t == "text":
            lines.append(pad + n["text"])
        elif t == "button":
            lines.append(f"{pad}[ {n['label']} ]")
        elif t == "input":
            shown = n["value"] or n["placeholder"] and f"({n['placeholder']})"
            lines.append(f"{pad}[_{shown or ''}_]")
        elif t == "link":
            lines.append(f"{pad}{n['text']} -> {n['target']}")
        elif t == "divider":
            lines.append(pad + "-" * 40)
        elif t in ("row", "column"):
            lines.append(f"{pad}<{t}>")
            lines += render_text(n["children"], indent + 1)
    return lines
