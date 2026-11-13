/* Tern 0.3 engine: lexer, parser, type checker, runtime.
 * No DOM in here, so it can be tested with plain node. */
(function (root) {
'use strict';

class TernError extends Error {
  constructor(msg, pos, phase) {
    super(msg);
    this.msg = msg; this.pos = pos || [0, 0]; this.phase = phase || 'error'; this.file = null;
  }
  toString() { return `${this.phase}${this.file ? ' in ' + this.file : ''} at line ${this.pos[0]}, column ${this.pos[1]}: ${this.msg}`; }
}

// ---------------------------------------------------------------- types
const INT = 'Int', TEXT = 'Text', BOOL = 'Bool', UNIT = 'Unit', COLOR = 'Color', ALIGN = 'Align', FLOAT = 'Float', FONT = 'Font', ACTION = 'Action';
const BASE_TYPES = { Int: INT, Float: FLOAT, Text: TEXT, Bool: BOOL, Color: COLOR, Align: ALIGN, Font: FONT, Action: ACTION };
const isList = t => Array.isArray(t);
const tname = t => (isList(t) ? `List<${tname(t[1])}>` : t);
const teq = (a, b) => (isList(a) ? isList(b) && teq(a[1], b[1]) : a === b);

const COLORS = {
  black: '#000000', white: '#ffffff', gray: '#6e7781', red: '#d1242f', green: '#1a7f37',
  blue: '#0b57d0', orange: '#bc4c00', purple: '#8250df', yellow: '#bf8700', pink: '#bf3989',
};
const ALIGNS = { left: 'left', center: 'center', right: 'right', spread: 'spread' };
const FONTS = ['sans', 'serif', 'mono', 'display', 'hand', 'rounded'];
const CONST_TYPES = {};
const CONST_VALUES = {};
for (const k in COLORS) { CONST_TYPES[k] = COLOR; CONST_VALUES[k] = COLORS[k]; }
for (const k in ALIGNS) { CONST_TYPES[k] = ALIGN; CONST_VALUES[k] = ALIGNS[k]; }
for (const k of FONTS) { CONST_TYPES[k] = FONT; CONST_VALUES[k] = k; }

// ---------------------------------------------------------------- lexer
const KEYWORDS = new Set([
  'page', 'state', 'fn', 'view', 'let', 'if', 'else', 'for', 'foreach', 'in', 'return', 'true', 'false', 'null',
  'to', 'placeholder', 'text', 'heading', 'button', 'input', 'row', 'column', 'link', 'divider',
  // 0.2
  'style', 'size', 'color', 'background', 'align', 'padding', 'bold', 'italic', 'underline',
  'strike', 'when', 'para', 'span', 'table', 'header', 'cells', 'bullet',
  // 0.3
  'image', 'alt', 'width', 'height', 'radius', 'border', 'font', 'goto', 'back',
  // 0.4
  'checkbox', 'resizable', 'modal',
  // layout
  'gap', 'margin', 'grow', 'maxwidth', 'minwidth', 'grid',
  // choices
  'select', 'radio', 'textarea', 'slider', 'disabled',
  // saved state, timers
  'saved', 'every',
  'struct', 'with', 'use', 'self',
  'component', 'import',
  'action',
]);
const TOKEN_RE = new RegExp(
  '(?<ws>[ \\t\\r]+)|(?<nl>\\n)|(?<comment>//[^\\n]*)|' +
  '(?<hex>#[0-9A-Fa-f]{6}\\b|#[0-9A-Fa-f]{3}\\b)|(?<float>\\d+\\.\\d+)|(?<int>\\d+)|(?<str>"(?:[^"\\\\\\n]|\\\\.)*")|' +
  '(?<id>[A-Za-z_][A-Za-z0-9_]*)|(?<op>->|==|!=|<=|>=|&&|\\|\\||[{}()\\[\\],:=<>+\\-*/%!?.])', 'y');
const GROUPS = ['ws', 'nl', 'comment', 'hex', 'float', 'int', 'str', 'id', 'op'];
const ESC = { n: '\n', t: '\t', '"': '"', '\\': '\\' };

function tokenize(src) {
  const toks = [];
  let i = 0, line = 1, ls = 0;
  while (i < src.length) {
    TOKEN_RE.lastIndex = i;
    const m = TOKEN_RE.exec(src);
    const pos = [line, i - ls + 1];
    if (!m || m.index !== i) {
      if (src[i] === '"') throw new TernError('unterminated string', pos, 'syntax error');
      throw new TernError(`unexpected character '${src[i]}'`, pos, 'syntax error');
    }
    const kind = GROUPS.find(g => m.groups[g] !== undefined);
    const text = m[0];
    i = TOKEN_RE.lastIndex;
    if (kind === 'nl') { line++; ls = i; }
    else if (kind === 'ws' || kind === 'comment') { /* skip */ }
    else if (kind === 'int') toks.push({ kind: 'int', val: parseInt(text, 10), pos });
    else if (kind === 'float') toks.push({ kind: 'float', val: parseFloat(text), pos });
    else if (kind === 'hex') {
      let h = text.slice(1).toLowerCase();
      if (h.length === 3) h = h.split('').map(c => c + c).join('');
      toks.push({ kind: 'hex', val: '#' + h, pos });
    } else if (kind === 'str') {
      const body = text.slice(1, -1);
      let out = '';
      for (let j = 0; j < body.length; j++) {
        if (body[j] === '\\') {
          const c = body[j + 1];
          if (!(c in ESC)) throw new TernError(`unknown escape \\${c}`, pos, 'syntax error');
          out += ESC[c]; j++;
        } else out += body[j];
      }
      toks.push({ kind: 'str', val: out, pos });
    } else if (kind === 'id') toks.push({ kind: KEYWORDS.has(text) ? 'kw' : 'id', val: text, pos });
    else toks.push({ kind: 'op', val: text, pos });
  }
  toks.push({ kind: 'eof', val: 'end of file', pos: [line, i - ls + 1] });
  return toks;
}

// ---------------------------------------------------------------- parser
const N = (kind, pos, props) => Object.assign({ kind, pos }, props);
const BIN_LEVELS = [['||'], ['&&'], ['==', '!='], ['<', '>', '<=', '>='], ['+', '-'], ['*', '/', '%']];
const FLAGS = new Set(['bold', 'italic', 'underline', 'strike', 'disabled']);
const VALUE_MODS = new Set(['size', 'color', 'background', 'align', 'padding', 'font', 'radius', 'border', 'width', 'height', 'alt', 'gap', 'margin', 'grow', 'maxwidth', 'minwidth']);

class Parser {
  // o.lib: parsing a .ternlib file; o.prefix: "shop." added to the names it declares; o.mods: libraries a page uses
  constructor(toks, o = {}) {
    this.t = toks; this.i = 0; this.structNames = new Set(); this.ownFns = new Set();
    this.lib = !!o.lib; this.prefix = o.prefix || ''; this.libs = o.mods || {};
    for (let k = 0; k + 1 < toks.length; k++) {
      if (toks[k].kind !== 'kw' || toks[k + 1].kind !== 'id') continue;
      if (toks[k].val === 'struct') this.structNames.add(toks[k + 1].val);
      if (toks[k].val === 'fn') this.ownFns.add(toks[k + 1].val);
    }
    for (const m in this.libs) for (const st of this.libs[m].structs) this.structNames.add(`${m}.${st}`);
  }
  notModule(tok) {
    if (this.libs[tok.val]) throw new TernError(`'${tok.val}' is the name of a library you use; pick another name`, tok.pos, 'syntax error');
    return tok;
  }
  peek(k = 0) { return this.t[Math.min(this.i + k, this.t.length - 1)]; }
  next() { const t = this.peek(); this.i++; return t; }
  is(val, k = 0) { const t = this.peek(k); return (t.kind === 'kw' || t.kind === 'op') && t.val === val; }
  accept(val) { return this.is(val) ? this.next() : null; }
  expect(val) {
    if (!this.is(val)) {
      const t = this.peek();
      throw new TernError(`expected '${val}' but found '${t.val}'`, t.pos, 'syntax error');
    }
    return this.next();
  }
  ident(what = 'a name') {
    const t = this.peek();
    if (t.kind !== 'id') throw new TernError(`expected ${what} but found '${t.val}'`, t.pos, 'syntax error');
    return this.next();
  }
  nextKind(kind, what) {
    const t = this.peek();
    if (t.kind !== kind) throw new TernError(`expected ${what} but found '${t.val}'`, t.pos, 'syntax error');
    return this.next();
  }

  program() {
    let title = null;
    const states = [], fns = [], styles = [], views = [], structs = [], components = [], imports = [];
    const uses = [];
    if (this.lib && this.is('page')) throw new TernError('a library has no page title; it holds only struct and fn', this.peek().pos, 'syntax error');
    if (this.accept('page')) title = this.nextKind('str', 'a page title in quotes').val;
    while (this.peek().kind !== 'eof') {
      const t = this.peek();
      if (this.lib && (this.is('state') || this.is('view') || this.is('style') || this.is('use') || this.is('component') || this.is('import')))
        throw new TernError(this.is('use') ? 'a library cannot use other libraries yet' : `a library holds only struct and fn; keep '${t.val}' in the page`, t.pos, 'syntax error');
      if (this.is('use')) { this.next(); uses.push(N('use', t.pos, { file: this.nextKind('str', 'a library file name in quotes, like "shop.ternlib"').val })); }
      else if (this.is('import')) { this.next(); imports.push(this.componentImport()); }
      else if (this.is('struct')) structs.push(this.structDecl());
      else if (this.is('component')) components.push(this.componentDecl());
      else if (this.is('saved') && this.is('state', 1)) { this.next(); const d = this.stateDecl(); d.saved = true; states.push(d); }
      else if (this.is('state')) states.push(this.stateDecl());
      else if (this.is('fn')) fns.push(this.fnDecl());
      else if (this.is('style')) styles.push(this.styleDecl());
      else if (this.is('view')) {
        this.next();
        const name = this.peek().kind === 'id' ? this.next().val : 'home';
        views.push(N('view', t.pos, { name, body: this.viewBlock() }));
      } else throw new TernError(`expected 'use', 'import', 'struct', 'component', 'state', 'fn', 'style' or 'view' but found '${t.val}'`, t.pos, 'syntax error');
    }
    if (!views.length && !this.lib && !components.length) throw new TernError('page has no view', this.peek().pos, 'syntax error');
    return N('program', [1, 1], { title, uses, imports, structs, components, states, fns, styles, views });
  }

  type() {
    const t = this.ident('a type');
    if (BASE_TYPES[t.val]) return BASE_TYPES[t.val];
    if (this.libs[t.val] && this.is('.')) {
      this.next(); const m = this.ident('a struct name');
      if (!this.libs[t.val].structs.has(m.val)) throw new TernError(`library ${t.val} has no struct '${m.val}'`, m.pos, 'syntax error');
      return `${t.val}.${m.val}`;
    }
    if (this.structNames.has(t.val)) return this.prefix + t.val;
    if (t.val === 'List') { this.expect('<'); const inner = this.type(); this.expect('>'); return ['List', inner]; }
    throw new TernError(`unknown type '${t.val}' (try Int, Text, Bool, Color, Align, List<...> or a struct you declared)`, t.pos, 'syntax error');
  }
  structDecl() {
    const pos = this.next().pos;
    const nameTok = this.ident('a struct name');
    this.expect('{');
    const fields = [], methods = [];
    while (!this.is('}')) {
      const ft = this.peek();
      if (this.is('fn')) { methods.push(this.fnDecl(true)); continue; }
      if (ft.kind === 'kw') throw new TernError(`'${ft.val}' is a reserved word and cannot be a field name; try another, like ${ft.val}Value`, ft.pos, 'syntax error');
      if (ft.kind === 'eof') throw new TernError("missing '}'", ft.pos, 'syntax error');
      const f = this.ident('a field name'); this.expect(':');
      const ty = this.type();
      const def = this.accept('=') ? this.expr() : null;
      fields.push([f.val, ty, f.pos, def]);
      this.accept(',');
    }
    this.expect('}');
    return N('structdecl', pos, { name: this.prefix + nameTok.val, namePos: nameTok.pos, fields, methods });
  }
  componentDecl() {
    const pos = this.next().pos;
    const nameTok = this.ident('a component name');
    this.expect('(');
    const propName = this.ident('a parameter name').val; this.expect(':');
    const propType = this.type();
    this.expect(')');
    return N('componentdecl', pos, { name: this.prefix + nameTok.val, propName, propType, body: this.viewBlock() });
  }
  componentImport() {
    const pos = this.peek().pos;
    this.expect('component');
    const name = this.ident('a component name').val;
    let file = name + '.tern';
    const nx = this.peek();
    if ((nx.kind === 'id' || nx.kind === 'kw') && nx.val === 'from') { this.next(); file = this.nextKind('str', 'a component file name in quotes').val; }
    else if (nx.kind === 'str') { file = this.next().val; }
    return N('compimport', pos, { name, file });
  }
  stateDecl() {
    const pos = this.next().pos;
    const name = this.notModule(this.ident('a state name')).val;
    this.expect(':'); const type = this.type(); this.expect('=');
    return N('state', pos, { name, type, init: this.expr() });
  }
  styleDecl() {
    const pos = this.next().pos;
    const name = this.ident('a style name').val;
    this.expect('{');
    const mods = this.mods();
    this.expect('}');
    return N('styledecl', pos, { name, mods });
  }
  fnDecl(method = false) {
    const pos = this.next().pos;
    const nameTok = this.notModule(this.ident(method ? 'a method name' : 'a function name'));
    if (!method && this.lib && BUILTINS[nameTok.val] !== undefined) throw new TernError(`'${nameTok.val}' is a built-in name; pick another name for this function`, nameTok.pos, 'syntax error');
    const name = method ? nameTok.val : this.prefix + nameTok.val;
    this.expect('(');
    const params = [];
    while (!this.is(')')) {
      const p = this.notModule(this.ident('a parameter name')); this.expect(':');
      params.push([p.val, this.type(), p.pos]);
      if (!this.accept(',')) break;
    }
    this.expect(')');
    const ret = this.accept(':') ? this.type() : UNIT;
    return N('fn', pos, { name, params, ret, body: this.block() });
  }

  // ---- modifiers: size 20 bold color red style note ...
  mods() {
    const out = [];
    for (;;) {
      const t = this.peek();
      if (t.kind !== 'kw') break;
      if (FLAGS.has(t.val)) {
        this.next();
        out.push(N('mod', t.pos, { name: t.val, value: null, when: this.accept('when') ? this.expr() : null }));
      } else if (VALUE_MODS.has(t.val)) {
        this.next();
        out.push(N('mod', t.pos, { name: t.val, value: this.expr(), when: null }));
      } else if (t.val === 'style') {
        this.next();
        const names = [this.ident('a style name')];
        while (this.peek().kind === 'id') names.push(this.next());
        out.push(N('mod', t.pos, { name: 'style', value: names.map(n => [n.val, n.pos]), when: null }));
      } else break;
    }
    return out;
  }

  // ---- statements
  block() {
    this.expect('{');
    const out = [];
    while (!this.is('}')) {
      if (this.peek().kind === 'eof') throw new TernError("missing '}'", this.peek().pos, 'syntax error');
      out.push(this.stmt());
    }
    this.expect('}');
    return out;
  }
  stmt() {
    const t = this.peek();
    if (this.accept('let')) {
      const name = this.notModule(this.ident('a variable name')).val;
      const type = this.accept(':') ? this.type() : null;
      this.expect('=');
      return N('let', t.pos, { name, type, value: this.expr() });
    }
    if (this.accept('if')) {
      const cond = this.expr(), then = this.block();
      let other = [];
      if (this.accept('else')) other = this.is('if') ? [this.stmt()] : this.block();
      return N('if', t.pos, { cond, then, other });
    }
    if (this.accept('for') || this.accept('foreach')) {
      const v = this.notModule(this.ident('a loop variable')).val; this.expect('in');
      return N('for', t.pos, { var: v, iter: this.expr(), body: this.block() });
    }
    if (this.accept('goto')) return N('goto', t.pos, { name: this.ident('the name of a page').val });
    if (this.accept('back')) return N('back', t.pos, {});
    if (this.accept('return')) {
      if (this.is('}')) return N('return', t.pos, { value: null });
      return N('return', t.pos, { value: this.expr() });
    }
    if (t.kind === 'id' && this.is('=', 1)) {
      this.next(); this.next();
      return N('assign', t.pos, { name: t.val, value: this.expr() });
    }
    const e = this.expr();
    if (this.is('=')) {
      const eq = this.next();
      if (e.kind === 'index') throw new TernError('a list is changed with setAt, like: xs = setAt(xs, i, value)', eq.pos, 'syntax error');
      if (e.kind !== 'field') throw new TernError('you can change a variable or a field, like: x = 1 or item.qty = 2', eq.pos, 'syntax error');
      return N('setpath', t.pos, { target: e, value: this.expr() });
    }
    return N('expr', t.pos, { value: e });
  }

  // ---- expressions
  expr(lvl = 0) {
    if (lvl === BIN_LEVELS.length) return this.unary();
    let left = this.expr(lvl + 1);
    while (this.peek().kind === 'op' && BIN_LEVELS[lvl].includes(this.peek().val)) {
      const op = this.next();
      left = N('bin', op.pos, { op: op.val, l: left, r: this.expr(lvl + 1) });
    }
    return left;
  }
  unary() {
    const t = this.peek();
    if (t.kind === 'op' && (t.val === '!' || t.val === '-')) {
      this.next();
      return N('un', t.pos, { op: t.val, e: this.unary() });
    }
    return this.postfix();
  }
  postfix() {
    let e = this.primary();
    for (;;) {
      if (e.kind === 'var' && this.libs[e.name] && this.is('.') && this.peek(1).kind === 'id') {
        this.next();
        const m = this.next(), info = this.libs[e.name];
        if (!info.fns.has(m.val) && !info.structs.has(m.val))
          throw new TernError(`library ${e.name} has no '${m.val}' (it has: ${[...info.fns, ...info.structs].join(', ') || 'nothing'})`, m.pos, 'syntax error');
        e = N('var', e.pos, { name: `${e.name}.${m.val}` });
      } else if (this.is('(') && e.kind === 'var') {
        this.next();
        if (this.structNames.has(e.name)) {
          const fields = [];
          while (!this.is(')')) {
            const f = this.peek();
            if (!(f.kind === 'id' && this.is(':', 1)))
              throw new TernError(`${e.name}(...) needs named fields, like ${e.name}(field: value, ...)`, f.pos, 'syntax error');
            this.next(); this.next();
            fields.push([f.val, this.expr(), f.pos]);
            if (!this.accept(',')) break;
          }
          this.expect(')');
          e = N('construct', e.pos, { name: this.lib ? this.prefix + e.name : e.name, fields });
          continue;
        }
        const args = [];
        while (!this.is(')')) { args.push(this.expr()); if (!this.accept(',')) break; }
        this.expect(')');
        e = N('call', e.pos, { name: this.lib && this.ownFns.has(e.name) ? this.prefix + e.name : e.name, args });
      } else if (this.is('.')) {
        const pos = this.next().pos;
        const nm = this.ident('a field or method name').val;
        if (this.is('(')) {
          this.next();
          const args = [];
          while (!this.is(')')) { args.push(this.expr()); if (!this.accept(',')) break; }
          this.expect(')');
          e = N('mcall', pos, { recv: e, name: nm, args });
        } else e = N('field', pos, { e, name: nm });
      } else if (this.is('with')) {
        const pos = this.next().pos;
        const updates = [];
        do {
          const f = this.ident('a field name'); this.expect(':');
          updates.push([f.val, this.expr(), f.pos]);
        } while (this.is(',') && this.peek(1).kind === 'id' && this.is(':', 2) && this.next());
        e = N('with', pos, { e, updates });
      } else if (this.is('[')) {
        const pos = this.next().pos;
        const idx = this.expr(); this.expect(']');
        e = N('index', pos, { e, idx });
      } else return e;
    }
  }
  primary() {
    const t = this.next();
    if (t.kind === 'int') return N('int', t.pos, { v: t.val });
    if (t.kind === 'str') return N('str', t.pos, { v: t.val });
    if (t.kind === 'hex') return N('color', t.pos, { v: t.val });
    if (t.kind === 'float') return N('float', t.pos, { v: t.val });
    if (t.kind === 'id') return N('var', t.pos, { name: t.val });
    if (t.kind === 'kw' && t.val === 'self') return N('var', t.pos, { name: 'self' });
    if (t.kind === 'kw' && (t.val === 'true' || t.val === 'false')) return N('bool', t.pos, { v: t.val === 'true' });
    if (t.kind === 'kw' && t.val === 'action') return N('action', t.pos, { body: this.block() });
    if (t.kind === 'op' && t.val === '[') {
      const items = [];
      while (!this.is(']')) { items.push(this.expr()); if (!this.accept(',')) break; }
      this.expect(']');
      return N('list', t.pos, { items });
    }
    if (t.kind === 'op' && t.val === '(') { const e = this.expr(); this.expect(')'); return e; }
    throw new TernError(`expected an expression but found '${t.val}'`, t.pos, 'syntax error');
  }

  // ---- view
  viewBlock() {
    this.expect('{');
    const out = [];
    while (!this.is('}')) {
      if (this.peek().kind === 'eof') throw new TernError("missing '}'", this.peek().pos, 'syntax error');
      out.push(this.viewItem());
    }
    this.expect('}');
    return out;
  }
  componentArgs() {
    const args = [];
    while (!this.is(')')) {
      const f = this.peek();
      if (!(f.kind === 'id' && this.is(':', 1))) throw new TernError('a component needs named properties, like Card(title: "Hi")', f.pos, 'syntax error');
      this.next(); this.next();
      args.push([f.val, this.expr(), f.pos]);
      if (!this.accept(',')) break;
    }
    this.expect(')');
    return args;
  }
  viewItem() {
    if (this.peek().kind === 'id' && this.is('(', 1)) {
      const t = this.next(); this.next();
      return N('component', t.pos, { name: t.val, args: this.componentArgs() });
    }
    const t = this.next();
    const k = t.kind === 'kw' ? t.val : null;
    if (k === 'heading' || k === 'text' || k === 'bullet') {
      const e = this.expr();
      return N(k, t.pos, { e, mods: this.mods() });
    }
    if (k === 'button') {
      const label = this.expr(), mods = this.mods();
      this.expect('->');
      const action = this.is('{') ? this.block() : [this.stmt()];
      return N('button', t.pos, { label, mods, action });
    }
    if (k === 'modal') {   // modal <Bool> [style words] [-> action] { ... }
      const e = this.expr(), mods = this.mods();
      const action = this.accept('->') ? (this.is('{') ? this.block() : [this.stmt()]) : null;
      return N('modal', t.pos, { e, mods, action, body: this.viewBlock() });
    }
    if (k === 'every') {   // every <milliseconds> [when <Bool>] -> action
      const ms = this.expr(), when = this.accept('when') ? this.expr() : null;
      this.expect('->');
      return N('every', t.pos, { ms, when, action: this.is('{') ? this.block() : [this.stmt()] });
    }
    if (k === 'textarea') {   // textarea <Text place> [placeholder "x"] [style words]
      const target = this.expr();
      if (target.kind !== 'var' && target.kind !== 'field' && target.kind !== 'index')
        throw new TernError('textarea edits a Text state, like: textarea notes   or a place inside one, like: textarea items[i]', target.pos, 'syntax error');
      return N('textarea', t.pos, { target, placeholder: this.accept('placeholder') ? this.expr() : null, mods: this.mods() });
    }
    if (k === 'slider') {   // slider <Int place> in <low> to <high> [style words]
      const target = this.expr();
      if (target.kind !== 'var' && target.kind !== 'field' && target.kind !== 'index')
        throw new TernError('slider edits an Int state, like: slider volume in 0 to 100   or a place inside one, like: slider levels[i] in 0 to 10', target.pos, 'syntax error');
      this.expect('in'); const lo = this.expr(); this.expect('to'); const hi = this.expr();
      return N('slider', t.pos, { target, lo, hi, mods: this.mods() });
    }
    if (k === 'select' || k === 'radio') {   // select <Text place> in <List<Text>> [placeholder "x"] [style words]
      const target = this.expr();
      if (target.kind !== 'var' && target.kind !== 'field' && target.kind !== 'index')
        throw new TernError(`${k} edits a Text state, like: ${k} choice in options   or a place inside one, like: ${k} items[i] in options`, target.pos, 'syntax error');
      this.expect('in');
      const options = this.expr();
      const placeholder = k === 'select' && this.accept('placeholder') ? this.expr() : null;
      return N(k, t.pos, { target, options, placeholder, mods: this.mods() });
    }
    if (k === 'checkbox') {
      const c = this.checkboxParts();
      return N('checkbox', t.pos, c);
    }
    if (k === 'input') {
      const target = this.expr();   // a Text state, or a place inside one: names[i]  people[i].name
      if (target.kind !== 'var' && target.kind !== 'field' && target.kind !== 'index')
        throw new TernError('input edits a Text state, like: input name   or a place inside one, like: input names[i]', target.pos, 'syntax error');
      return N('input', t.pos, { target, name: target.kind === 'var' ? target.name : '', placeholder: this.accept('placeholder') ? this.expr() : null, mods: this.mods() });
    }
    if (k === 'row' || k === 'column') {
      const mods = this.mods();
      return N(k, t.pos, { mods, body: this.viewBlock() });
    }
    if (k === 'grid') {   // grid <columns> [style words] { ... }
      const cols = this.expr(), mods = this.mods();
      return N('grid', t.pos, { cols, mods, body: this.viewBlock() });
    }
    if (k === 'para') {
      const mods = this.mods();
      this.expect('{');
      const spans = [];
      while (!this.is('}')) {
        const s = this.peek();
        if (!this.accept('span')) throw new TernError(`inside para, write: span "text"  (found '${s.val}')`, s.pos, 'syntax error');
        const e = this.expr();
        spans.push(N('span', s.pos, { e, mods: this.mods() }));
      }
      this.expect('}');
      return N('para', t.pos, { mods, spans });
    }
    if (k === 'table') {
      let mods = [], resizable = false;
      for (;;) {   // 'resizable' and the style words may come in any order
        const m = this.mods(); mods = mods.concat(m);
        if (this.accept('resizable')) { resizable = true; continue; }
        if (!m.length) break;
      }
      return N('table', t.pos, { mods, resizable, body: this.tableBlock() });
    }
    if (k === 'if') {
      const cond = this.expr(), then = this.viewBlock();
      let other = [];
      if (this.accept('else')) other = this.is('if') ? [this.viewItem()] : this.viewBlock();
      return N('vif', t.pos, { cond, then, other });
    }
    if (k === 'for' || k === 'foreach') {
      const v = this.notModule(this.ident('a loop variable')).val; this.expect('in');
      return N('vfor', t.pos, { var: v, iter: this.expr(), body: this.viewBlock() });
    }
    if (k === 'link') {
      const label = this.expr();
      const mods = this.mods();
      if (this.accept('->')) {
        const action = this.is('{') ? this.block() : [this.stmt()];
        return N('link', t.pos, { label, target: null, action, mods });
      }
      this.expect('to');
      const target = this.expr();
      return N('link', t.pos, { label, target, action: null, mods: mods.concat(this.mods()) });
    }
    if (k === 'image') {
      const e = this.expr();
      return N('image', t.pos, { e, mods: this.mods() });
    }
    if (k === 'divider') return N('divider', t.pos, {});
    throw new TernError(`expected a view element (text, heading, button, ...) but found '${t.val}'`, t.pos, 'syntax error');
  }
  tableBlock() {
    this.expect('{');
    const out = [];
    while (!this.is('}')) {
      if (this.peek().kind === 'eof') throw new TernError("missing '}'", this.peek().pos, 'syntax error');
      out.push(this.tableItem());
    }
    this.expect('}');
    return out;
  }
  tableItem() {
    const t = this.next();
    const k = t.kind === 'kw' ? t.val : null;
    if (k === 'header' || k === 'cells') {
      const cells = [this.cell()];
      while (this.accept(',')) cells.push(this.cell());
      return N(k, t.pos, { cells });
    }
    if (k === 'if') {
      const cond = this.expr(), then = this.tableBlock();
      let other = [];
      if (this.accept('else')) other = this.is('if') ? [this.tableItem2()] : this.tableBlock();
      return N('vif', t.pos, { cond, then, other });
    }
    if (k === 'for' || k === 'foreach') {
      const v = this.notModule(this.ident('a loop variable')).val; this.expect('in');
      return N('vfor', t.pos, { var: v, iter: this.expr(), body: this.tableBlock() });
    }
    throw new TernError(`inside a table you can use 'header', 'cells', 'if', 'for' and 'foreach' (found '${t.val}')`, t.pos, 'syntax error');
  }
  tableItem2() { return this.tableItem(); }
  // checkbox <Bool> ["label"] [style words] [-> action]
  checkboxParts() {
    const e = this.expr(), nx = this.peek();
    const label = (nx.kind === 'str' || nx.kind === 'id' || this.is('(')) ? this.expr() : null;
    const mods = this.mods();
    const action = this.accept('->') ? (this.is('{') ? this.block() : [this.stmt()]) : null;
    return { e, label, mods, action };
  }
  // One cell: a Text value, or a button or link, optionally followed by: span 2
  cell() {
    const t = this.peek();
    let c;
    if (this.accept('button')) {
      const e = this.expr(), mods = this.mods();
      this.expect('->');
      c = N('cell', t.pos, { kind: 'button', e, mods, action: this.is('{') ? this.block() : [this.stmt()], target: null });
    } else if (this.accept('link')) {
      const e = this.expr();
      let mods = this.mods(), action = null, target = null;
      if (this.accept('->')) action = this.is('{') ? this.block() : [this.stmt()];
      else { this.expect('to'); target = this.expr(); mods = mods.concat(this.mods()); }
      c = N('cell', t.pos, { kind: 'link', e, mods, action, target });
    } else if (this.accept('select')) {
      const place = this.expr(); this.expect('in');
      const opts = this.expr();
      c = N('cell', t.pos, { kind: 'select', e: this.accept('placeholder') ? this.expr() : N('str', t.pos, { v: '' }), cond: place, opts, mods: [], action: null, target: null });
    } else if (this.accept('input')) {
      const place = this.expr();
      c = N('cell', t.pos, { kind: 'input', e: this.accept('placeholder') ? this.expr() : N('str', t.pos, { v: '' }), cond: place, mods: [], action: null, target: null });
    } else if (this.accept('checkbox')) {
      const p = this.checkboxParts();
      c = N('cell', t.pos, { kind: 'checkbox', e: p.label || N('str', t.pos, { v: '' }), cond: p.e, mods: p.mods, action: p.action, target: null });
    } else { const e = this.expr(); c = N('cell', t.pos, { kind: 'text', e, mods: [], action: null, target: null }); }
    c.span = 1;
    for (;;) {   // style words and 'span N' may come in either order
      if (c.kind === 'text') { const m = this.mods(); if (m.length) { c.mods = c.mods.concat(m); continue; } }
      if (!this.accept('span')) break;
      const n = this.next();
      if (n.kind !== 'int') throw new TernError("write the number of columns after 'span', like: span 2", n.pos, 'syntax error');
      c.span = n.val; c.spanPos = n.pos;
    }
    return c;
  }
}

function parse(src, o) { return new Parser(tokenize(src), o).program(); }

function buildLibraries(src, opts) {
  const toks = tokenize(src), mods = {}, libs = [];
  for (let k = 0; k + 1 < toks.length; k++) {
    if (!(toks[k].kind === 'kw' && toks[k].val === 'use' && toks[k + 1].kind === 'str')) continue;
    const file = toks[k + 1].val, pos = toks[k].pos;
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\.ternlib$/.exec(file);
    if (!m) throw new TernError('a library is named like use "shop.ternlib" (a file next to this page, with no folders)', pos, 'syntax error');
    const name = m[1];
    if (name in mods) throw new TernError(`library ${file} is used twice`, pos, 'syntax error');
    if (KEYWORDS.has(name) || BUILTINS[name] !== undefined || BASE_TYPES[name]) throw new TernError(`'${name}' cannot be a library name; rename the file`, pos, 'syntax error');
    const libs0 = opts.libraries || {};
    if (!Object.prototype.hasOwnProperty.call(libs0, name) || typeof libs0[name] !== 'string')
      throw new TernError(`library ${file} was not found (${opts.libraryHint || 'put it next to the page'})`, pos, 'library error');
    let lp;
    try {
      lp = new Parser(tokenize(libs0[name]), { lib: true, prefix: name + '.' }).program();
      new Checker(lp, opts).run();
    } catch (e) { if (e instanceof TernError) e.file = file; throw e; }
    const strip = n => n.slice(name.length + 1);
    mods[name] = { fns: new Set(lp.fns.map(f => strip(f.name))), structs: new Set(lp.structs.map(s => strip(s.name))) };
    libs.push(lp);
  }
  return { mods, libs };
}

// Reads a page and the libraries it names with `use "shop.ternlib"`. Each library is parsed and
// checked on its own first (so its errors name its file), then its structs and functions are added to
// the page under the prefix `shop.`. opts.libraries is { shop: "source text" }.
function buildProgram(src, opts, _seen) {
  opts = opts || {}; _seen = _seen || new Set();
  const { mods, libs } = buildLibraries(src, opts);
  const prog = new Parser(tokenize(src), { mods }).program();
  const compSources = opts.components || opts.componentSources || {};
  let compStructs = [], compDecls = [], compFns = [];
  for (const imp of (prog.imports || [])) {
    const csrc = compSources[imp.file] || compSources[imp.name + '.tern'] || compSources[imp.name];
    if (typeof csrc !== 'string') throw new TernError(`component ${imp.file} was not found (${opts.libraryHint || 'put it next to the page'})`, imp.pos, 'import error');
    const key = imp.file;
    if (_seen.has(key)) throw new TernError(`component ${imp.file} is imported in a cycle`, imp.pos, 'import error');
    const seen = new Set(_seen); seen.add(key);
    try {
      const cprog = buildProgram(csrc, opts, seen);
      const wanted = (cprog.components || []).filter(c => c.name === imp.name);
      if (!wanted.length) throw new TernError(`component ${imp.file} does not define '${imp.name}'`, imp.pos, 'import error');
      compStructs = compStructs.concat(cprog.structs || []);
      compDecls = compDecls.concat(wanted);
      compFns = compFns.concat(cprog.fns || []);
    } catch (e) { if (e instanceof TernError && !e.file) e.file = imp.file; throw e; }
  }
  const dedup = (arr, key) => { const s = new Set(); return arr.filter(x => !s.has(x[key]) && s.add(x[key])); };
  prog.structs = [...dedup([...libs.flatMap(l => l.structs), ...compStructs], 'name'), ...(prog.structs || [])];
  prog.components = [...dedup(compDecls, 'name'), ...(prog.components || [])];
  prog.fns = [...dedup([...libs.flatMap(l => l.fns), ...compFns], 'name'), ...(prog.fns || [])];
  prog.imports = prog.imports || [];
  return prog;
}

// ---------------------------------------------------------------- checker
const LAYOUT = ['margin', 'grow', 'maxwidth', 'minwidth'];   // size and spacing words most blocks accept
const TEXT_PROPS = ['size', 'bold', 'italic', 'underline', 'strike', 'color', 'background', 'align', 'font', 'padding', 'radius', 'border', 'style', ...LAYOUT];
const ALL_PROPS = ['size', 'bold', 'italic', 'underline', 'strike', 'color', 'background', 'align', 'font', 'padding', 'radius', 'border', 'width', 'height', 'alt', 'gap', ...LAYOUT];
const ALLOWED = {
  heading: new Set(TEXT_PROPS), text: new Set(TEXT_PROPS), bullet: new Set(TEXT_PROPS), para: new Set(TEXT_PROPS),
  span: new Set(['size', 'bold', 'italic', 'underline', 'strike', 'color', 'background', 'font', 'style']),
  link: new Set(['size', 'bold', 'italic', 'strike', 'color', 'font', 'style']),
  button: new Set(['size', 'bold', 'italic', 'color', 'background', 'font', 'padding', 'radius', 'border', 'width', 'style', 'margin', 'grow', 'disabled']),
  row: new Set(['background', 'padding', 'radius', 'border', 'width', 'style', 'gap', 'align', ...LAYOUT]),
  column: new Set(['background', 'padding', 'radius', 'border', 'width', 'style', 'gap', 'align', ...LAYOUT]),
  grid: new Set(['background', 'padding', 'radius', 'border', 'width', 'style', 'gap', ...LAYOUT]),
  image: new Set(['width', 'height', 'radius', 'border', 'align', 'alt', 'style', ...LAYOUT]),
  select: new Set(['size', 'color', 'font', 'width', 'style', 'disabled', ...LAYOUT]),
  radio: new Set(['size', 'color', 'font', 'style', 'margin', 'disabled']),
  input: new Set(['width', 'disabled', ...LAYOUT]),
  textarea: new Set(['width', 'height', 'size', 'font', 'disabled', ...LAYOUT]),
  slider: new Set(['width', 'color', 'disabled', ...LAYOUT]),
  modal: new Set(['width', 'background', 'padding', 'radius', 'border', 'style']),
  checkbox: new Set(['size', 'bold', 'italic', 'color', 'font', 'style', 'disabled']),
  table: new Set(['height', 'padding', 'size', 'color', 'background', 'border', 'font', 'style', ...LAYOUT]),
  cellrow: new Set(['size', 'bold', 'italic', 'underline', 'strike', 'color', 'background', 'align', 'font', 'style']),
};
const PROP_TYPES = { size: INT, padding: INT, radius: INT, width: INT, height: INT, gap: INT, margin: INT, grow: INT, maxwidth: INT, minwidth: INT, color: COLOR, background: COLOR,
  border: COLOR, align: ALIGN, font: FONT, alt: TEXT };
const BUILTINS = {
  toText: 1, len: 1, append: 2, removeAt: 2, range: 1, trim: 1, upper: 1, lower: 1,
  contains: 2, join: 2, rgb: 3, setAt: 3, slice: 3, sort: 1, sortOrder: 1, reverse: 1,
  toFloat: 1, round: 1, floor: 1, ceil: 1, fixed: 2, sqrt: 1, toIntOr: 2, toFloatOr: 2,
};

function alwaysReturns(stmts) {
  for (const s of stmts) {
    if (s.kind === 'return') return true;
    if (s.kind === 'if' && s.other.length && alwaysReturns(s.then) && alwaysReturns(s.other)) return true;
  }
  return false;
}

class Checker {
  constructor(prog, opts) {
    this.prog = prog; this.opts = opts || {}; this.structs = {}; this.components = {}; this.methods = {}; this.curMethod = null; this.stmtCall = null; this.states = {}; this.fns = {}; this.styles = {}; this.views = {};
    this.scopes = []; this.ret = null; this.tbl = null; this.nest = 0;
  }
  err(msg, node) { throw new TernError(msg, node.pos, 'type error'); }
  lookup(name) {
    for (let i = this.scopes.length - 1; i >= 0; i--) if (name in this.scopes[i]) return this.scopes[i][name];
    if (name in this.states) return this.states[name];
    return CONST_TYPES[name];
  }
  declare(name, ty, node) {
    const sc = this.scopes[this.scopes.length - 1];
    if (name in sc) this.err(`'${name}' is already defined here`, node);
    sc[name] = ty;
  }
  run() {
    const p = this.prog;
    for (const st of p.structs) {
      if (st.name in BASE_TYPES || st.name === 'List') this.err(`'${st.name}' is a built-in type name; pick another name for the struct`, { pos: st.namePos });
      if (st.name in this.structs) this.err(`struct '${st.name}' is defined twice`, { pos: st.namePos });
      if (!st.fields.length) this.err(`struct '${st.name}' needs at least one field`, st);
      const seen = new Set();
      for (const [fname, , fpos] of st.fields) {
        if (seen.has(fname) || fname === '__proto__') this.err(`field '${fname}' is ${fname === '__proto__' ? 'not allowed' : 'defined twice'} in struct ${st.name}`, { pos: fpos });
        seen.add(fname);
      }
      this.structs[st.name] = st;
      for (const m of st.methods) {
        const key = `${st.name}.${m.name}`;
        if (seen.has(m.name) || key in this.methods) this.err(`'${m.name}' is defined twice in struct ${st.name} (a method cannot share a name with a field)`, m);
        this.methods[key] = { params: m.params.map(x => x[1]), ret: m.ret, decl: m, struct: st.name };
      }
    }
    for (const st of p.structs) {
      const reach = (t, path) => {
        while (isList(t)) t = t[1];
        if (!(t in this.structs)) return;
        if (path.includes(t)) this.err(`struct ${st.name} contains itself (${[...path, t].join(' -> ')}); a struct cannot hold itself, even inside a list`, { pos: st.namePos });
        for (const f of this.structs[t].fields) reach(f[1], [...path, t]);
      };
      reach(st.name, []);
    }
    for (const c of (p.components || [])) {
      if (c.name in this.components || c.name in this.views || c.name in this.fns || c.name in this.states || c.name in this.styles || c.name in this.structs)
        this.err(`'${c.name}' is defined twice`, c);
      if (typeof c.propType !== 'string' || !(c.propType in this.structs))
        this.err(`component '${c.name}' needs a props struct type, like component ${c.name}(props: MyProps)`, c);
      this.components[c.name] = c;
    }
    for (const s of p.states) {
      if (s.name in this.states || s.name in this.fns) this.err(`'${s.name}' is defined twice`, s);
      this.states[s.name] = s.type;
    }
    for (const f of p.fns) {
      if (f.name in this.states || f.name in this.fns || f.name in BUILTINS) this.err(`'${f.name}' is defined twice or is a built-in name`, f);
      this.fns[f.name] = [f.params.map(x => x[1]), f.ret];
    }
    for (const s of p.styles) {
      if (s.name in this.styles) this.err(`style '${s.name}' is defined twice`, s);
      this.styles[s.name] = s;
    }
    for (const v of p.views) {
      if (v.name in this.views) this.err(`there are two pages called '${v.name}'; give each view its own name, like: view ${v.name === 'home' ? 'about' : v.name + '2'} { ... }`, v);
      this.views[v.name] = v;
    }
    this.scopes = [{}];
    for (const st of p.structs) for (const f of st.fields) if (f[3]) this.expectType(f[3], f[1], `default for field '${f[0]}' of ${st.name}`);
    for (const s of p.states) this.expectType(s.init, s.type, `state '${s.name}'`);
    for (const s of p.styles) {
      for (const m of s.mods) {
        if (m.name === 'style') this.err('a style cannot use another style', m);
        this.checkMods([m], 'text', m, true);
      }
    }
    for (const f of p.fns) {
      this.scopes = [{}];
      for (const [name, ty, pos] of f.params) this.declare(name, ty, { pos });
      this.ret = f.ret;
      this.block(f.body);
      if (f.ret !== UNIT && !alwaysReturns(f.body)) this.err(`function '${f.name}' must return ${tname(f.ret)} on every path`, f);
    }
    for (const st of p.structs) {
      for (const m of st.methods) {
        this.scopes = [{ self: st.name }];
        this.scopes.push({});
        for (const [name, ty, pos] of m.params) this.declare(name, ty, { pos });
        this.ret = m.ret; this.curMethod = m;
        this.block(m.body);
        this.curMethod = null;
        if (m.ret !== UNIT && !alwaysReturns(m.body)) this.err(`method '${m.name}' must return ${tname(m.ret)} on every path`, m);
      }
    }
    for (const c of (p.components || [])) {
      this.scopes = [{ [c.propName]: c.propType }, {}];
      this.ret = null;
      this.view(c.body);
    }
    for (const v of p.views) { this.ret = null; this.scopes = [{}]; this.view(v.body); }
    return this;
  }
  checkMods(mods, kind, node, anyKind) {
    const allowed = anyKind ? new Set([...ALL_PROPS, 'style']) : ALLOWED[kind];
    for (const m of mods) {
      if (!allowed.has(m.name)) this.err(`${/^[aeiou]/.test(kind) ? 'an' : 'a'} ${kind} cannot have '${m.name}'`, m);
      if (m.name === 'style') {
        for (const [n, pos] of m.value) if (!(n in this.styles)) this.err(`unknown style '${n}' (declare it with: style ${n} { ... })`, { pos });
      } else if (FLAGS.has(m.name)) {
        if (m.when) this.expectType(m.when, BOOL, `'${m.name} when'`);
      } else this.expectType(m.value, PROP_TYPES[m.name], `'${m.name}'`);
    }
  }
  block(stmts) { this.scopes.push({}); for (const s of stmts) this.stmt(s); this.scopes.pop(); }
  stmt(s) {
    switch (s.kind) {
      case 'let': {
        let ty;
        if (s.type) { this.expectType(s.value, s.type, `'${s.name}'`); ty = s.type; } else ty = this.expr(s.value);
        this.declare(s.name, ty, s); break;
      }
      case 'assign': {
        const ty = this.lookup(s.name);
        if (ty === undefined) this.err(`unknown variable '${s.name}'`, s);
        if (!(s.name in this.states) && s.name in CONST_TYPES && !this.scopes.some(sc => s.name in sc))
          this.err(`'${s.name}' is built in and cannot be changed`, s);
        this.expectType(s.value, ty, `'${s.name}'`); break;
      }
      case 'if': this.expectType(s.cond, BOOL, 'an if condition'); this.block(s.then); this.block(s.other); break;
      case 'for': {
        const ity = this.expr(s.iter);
        if (!isList(ity)) this.err(`can only loop over a List, not ${tname(ity)}`, s.iter);
        this.scopes.push({ [s.var]: ity[1], ['\0' + s.var]: true }); this.block(s.body); this.scopes.pop(); break;
      }
      case 'goto':
        if (!(s.name in this.views)) this.err(`there is no page called '${s.name}' (pages are declared with: view ${s.name} { ... })`, s);
        break;
      case 'back': break;
      case 'return':
        if (this.ret === null) this.err("'return' can only be used inside a function", s);
        if (s.value === null) { if (this.ret !== UNIT) this.err(`this function must return ${tname(this.ret)}`, s); }
        else this.expectType(s.value, this.ret, 'the returned value');
        break;
      case 'setpath': {
        const ty = this.expr(s.target);
        this.checkPath(s.target, s);
        this.expectType(s.value, ty, `the field '${s.target.name}'`); break;
      }
      case 'expr':
        if (s.value.kind !== 'call' && s.value.kind !== 'mcall') this.err('this expression does nothing; use a call or an assignment', s);
        this.stmtCall = s.value;
        this.expr(s.value); break;
    }
  }
  pathText(t) { return t.kind === 'var' ? t.name : t.kind === 'field' ? `${this.pathText(t.e)}.${t.name}` : t.kind === 'index' ? `${this.pathText(t.e)}[...]` : 'it'; }
  // a path like  x  x.f  x.f.g  xs[0].f  can be changed if it starts at a variable we may change
  checkPath(t, node) {
    if (t.kind === 'field' || t.kind === 'index') return this.checkPath(t.e, node);
    if (t.kind !== 'var') this.err('only a variable (or a field of one) can be changed, not a computed value', node);
    const name = t.name;
    if (name === 'self') {
      if (this.curMethod && this.curMethod.ret !== UNIT)
        this.err(`method '${this.curMethod.name}' returns a value, so it cannot change self; return a changed copy with 'with', or make it return nothing`, node);
      return;
    }
    for (let i = this.scopes.length - 1; i >= 0; i--) {
      if (name in this.scopes[i]) {
        if (this.scopes[i]['\0' + name]) this.err(`'${name}' is a copy of a list item, so changing it would be lost; change the list instead, like: xs[0].field = value`, node);
        return;
      }
    }
    if (name in this.states) return;
    this.err(`'${name}' cannot be changed`, node);
  }
  expectType(e, want, what) {
    const got = this.expr(e, want);
    if (!teq(got, want)) {
      const hint = want === TEXT && (got === INT || got === BOOL) ? ` (use toText(...) to convert ${tname(got)} to Text)` : '';
      this.err(`${what} needs ${tname(want)} but this is ${tname(got)}${hint}`, e);
    }
  }
  expr(e, expected) {
    switch (e.kind) {
      case 'int': return INT;
      case 'str': return TEXT;
      case 'bool': return BOOL;
      case 'color': return COLOR;
      case 'float': return FLOAT;
      case 'var': {
        const ty = this.lookup(e.name);
        if (ty === undefined) {
          if (e.name === 'self') this.err("'self' only exists inside a struct's methods", e);
          if (e.name in this.structs) this.err(`'${e.name}' is a struct; create one like ${e.name}(${this.structs[e.name].fields.map(f => f[0] + ': ...').join(', ')})`, e);
          if (e.name in this.fns || e.name in BUILTINS) this.err(`'${e.name}' is a function; call it like ${e.name}(...)`, e);
          this.err(`unknown name '${e.name}'`, e);
        }
        return ty;
      }
      case 'list': {
        if (!e.items.length) {
          if (isList(expected)) return expected;
          this.err('cannot tell what an empty list holds; add a type, e.g. let xs: List<Int> = []', e);
        }
        const first = this.expr(e.items[0], isList(expected) ? expected[1] : undefined);
        for (const it of e.items.slice(1)) this.expectType(it, first, 'every list item');
        return ['List', first];
      }
      case 'un':
        if (e.op === '!') { this.expectType(e.e, BOOL, "'!'"); return BOOL; }
        { const t = this.expr(e.e); if (t !== INT && t !== FLOAT) this.err(`unary '-' needs Int or Float but this is ${tname(t)}`, e.e); return t; }
      case 'bin': return this.binary(e);
      case 'index': {
        const lt = this.expr(e.e);
        if (!isList(lt)) this.err(`can only index a List, not ${tname(lt)}`, e);
        this.expectType(e.idx, INT, 'a list index');
        return lt[1];
      }
      case 'action': {
        const saved = this.ret; this.ret = UNIT;
        this.block(e.body);
        this.ret = saved;
        return ACTION;
      }
      case 'call': {
        const ty = this.lookup(e.name);
        if (ty === ACTION && !(e.name in this.fns) && !(e.name in BUILTINS)) {
          const isStmt = this.stmtCall === e; this.stmtCall = null;
          if (e.args.length) this.err('an Action takes no arguments', e);
          if (!isStmt) this.err(`an Action does something, so use it as its own statement, like: ${e.name}()`, e);
          return UNIT;
        }
        return this.call(e, expected);
      }
      case 'construct': {
        const st = this.structs[e.name], given = new Set();
        for (const [fname, val, fpos] of e.fields) {
          const f = st.fields.find(x => x[0] === fname);
          if (!f) this.err(`${e.name} has no field '${fname}' (its fields are ${st.fields.map(x => x[0]).join(', ')})`, { pos: fpos });
          if (given.has(fname)) this.err(`field '${fname}' is given twice`, { pos: fpos });
          given.add(fname);
          this.expectType(val, f[1], `field '${fname}' of ${e.name}`);
        }
        const missing = st.fields.filter(f => !given.has(f[0]) && !f[3]);
        if (missing.length) this.err(`${e.name} needs ${missing.map(f => `${f[0]}: ${tname(f[1])}`).join(', ')}`, e);
        return e.name;
      }
      case 'mcall': {
        const isStmt = this.stmtCall === e; this.stmtCall = null;
        const t = this.expr(e.recv);
        if (typeof t !== 'string' || !(t in this.structs)) this.err(`only a struct has methods, but this is ${tname(t)}`, e);
        const af = this.structs[t].fields.find(f => f[0] === e.name);
        if (af && af[1] === ACTION) {
          if (e.args.length) this.err('an Action takes no arguments', e);
          if (!isStmt) this.err(`an Action does something, so use it as its own statement, like: ${this.pathText(e.recv)}.${e.name}()`, e);
          e.actionField = true;
          return UNIT;
        }
        const m = this.methods[`${t}.${e.name}`];
        if (!m) {
          const have = this.structs[t].methods.map(x => x.name);
          const isField = this.structs[t].fields.some(f => f[0] === e.name);
          this.err(`${t} has no method '${e.name}'${isField ? ' (it is a field; leave off the brackets)' : ` (its methods are ${have.join(', ') || 'none'})`}`, e);
        }
        if (e.args.length !== m.params.length) this.err(`${e.name}() takes ${m.params.length} argument(s) but got ${e.args.length}`, e);
        e.args.forEach((a, i) => this.expectType(a, m.params[i], `an argument of ${e.name}()`));
        e.method = `${t}.${e.name}`;
        if (m.ret !== UNIT) return m.ret;
        // a method that returns nothing may change the struct, so it must run on a variable and be its own statement
        if (!isStmt) this.err(`${e.name}() may change ${this.pathText(e.recv)}, so use it as its own statement, like: ${this.pathText(e.recv)}.${e.name}(...)`, e);
        this.checkPath(e.recv, e);
        e.writeBack = true;
        return UNIT;
      }
      case 'field': {
        const t = this.expr(e.e);
        if (typeof t !== 'string' || !(t in this.structs)) this.err(`only a struct has fields, but this is ${tname(t)}`, e);
        const f = this.structs[t].fields.find(x => x[0] === e.name);
        if (!f) this.err(`${t} has no field '${e.name}' (its fields are ${this.structs[t].fields.map(x => x[0]).join(', ')})`, e);
        return f[1];
      }
      case 'with': {
        const t = this.expr(e.e);
        if (typeof t !== 'string' || !(t in this.structs)) this.err(`'with' needs a struct on its left, but this is ${tname(t)}`, e);
        const seen = new Set();
        for (const [fname, val, fpos] of e.updates) {
          const f = this.structs[t].fields.find(x => x[0] === fname);
          if (!f) this.err(`${t} has no field '${fname}' (its fields are ${this.structs[t].fields.map(x => x[0]).join(', ')})`, { pos: fpos });
          if (seen.has(fname)) this.err(`field '${fname}' is changed twice`, { pos: fpos });
          seen.add(fname);
          this.expectType(val, f[1], `field '${fname}' of ${t}`);
        }
        return t;
      }
    }
    throw new Error('unknown expression ' + e.kind);
  }
  binary(e) {
    const op = e.op;
    if (op === '&&' || op === '||') {
      this.expectType(e.l, BOOL, `'${op}'`); this.expectType(e.r, BOOL, `'${op}'`); return BOOL;
    }
    const lt = this.expr(e.l), rt = this.expr(e.r);
    if (op === '==' || op === '!=') {
      if (lt === ACTION || rt === ACTION) this.err('cannot compare Action values', e);
      if (!teq(lt, rt)) this.err(`cannot compare ${tname(lt)} with ${tname(rt)}`, e);
      return BOOL;
    }
    if (op === '+' && lt === TEXT && rt === TEXT) return TEXT;
    if (op === '+' && isList(lt) && teq(lt, rt)) return lt;
    e.opType = lt;
    if ((lt === FLOAT || rt === FLOAT) && lt !== rt && (lt === INT || rt === INT))
      this.err(`'${op}' cannot mix Int and Float (use toFloat(...) to turn an Int into a Float)`, e);
    if (lt === FLOAT && rt === FLOAT) {
      if (op === '%') this.err("'%' only works on Int", e);
      return ['<', '>', '<=', '>='].includes(op) ? BOOL : FLOAT;
    }
    if (lt !== INT || rt !== INT) {
      const hint = op === '+' && (lt === TEXT || rt === TEXT) ? ' (use toText(...) to join numbers into Text)' : '';
      this.err(`'${op}' cannot be used on ${tname(lt)} and ${tname(rt)}${hint}`, e);
    }
    return ['<', '>', '<=', '>='].includes(op) ? BOOL : INT;
  }
  call(e, expected) {
    const name = e.name;
    if (name in this.fns) {
      const [params, ret] = this.fns[name];
      if (e.args.length !== params.length) this.err(`${name}() takes ${params.length} argument(s) but got ${e.args.length}`, e);
      e.args.forEach((a, i) => this.expectType(a, params[i], `an argument of ${name}()`));
      return ret;
    }
    if (name in BUILTINS) return this.builtin(e, expected);
    this.err(`unknown function '${name}'`, e);
  }
  builtin(e, expected) {
    const { name, args } = e;
    if (args.length !== BUILTINS[name]) this.err(`${name}() takes ${BUILTINS[name]} argument(s) but got ${args.length}`, e);
    switch (name) {
      case 'toText': {
        const t = this.expr(args[0]);
        if (t !== INT && t !== FLOAT && t !== BOOL && t !== TEXT) this.err(`toText() works on Int, Float, Bool and Text, not ${tname(t)}`, e);
        e.argType = t;
        return TEXT;
      }
      case 'len': {
        const t = this.expr(args[0]);
        if (t !== TEXT && !isList(t)) this.err(`len() works on Text and List, not ${tname(t)}`, e);
        return INT;
      }
      case 'append': {
        const lt = this.expr(args[0], expected);
        if (!isList(lt)) this.err(`append() needs a List first, not ${tname(lt)}`, args[0]);
        this.expectType(args[1], lt[1], 'the appended item'); return lt;
      }
      case 'removeAt': {
        const lt = this.expr(args[0]);
        if (!isList(lt)) this.err(`removeAt() needs a List first, not ${tname(lt)}`, args[0]);
        this.expectType(args[1], INT, 'the index'); return lt;
      }
      case 'setAt': {
        const lt = this.expr(args[0], expected);
        if (!isList(lt)) this.err(`setAt() needs a List first, not ${tname(lt)}`, args[0]);
        this.expectType(args[1], INT, 'the index'); this.expectType(args[2], lt[1], 'the new value'); return lt;
      }
      case 'slice': {
        const lt = this.expr(args[0], expected);
        if (!isList(lt)) this.err(`slice() needs a List first, not ${tname(lt)}`, args[0]);
        this.expectType(args[1], INT, 'the start'); this.expectType(args[2], INT, 'the end'); return lt;
      }
      case 'reverse': {
        const lt = this.expr(args[0], expected);
        if (!isList(lt)) this.err(`reverse() needs a List, not ${tname(lt)}`, args[0]);
        return lt;
      }
      case 'sort': case 'sortOrder': {
        const lt = this.expr(args[0]);
        if (!isList(lt) || (lt[1] !== INT && lt[1] !== FLOAT && lt[1] !== TEXT))
          this.err(`${name}() needs a List of Int, Float or Text, not ${tname(lt)}`, args[0]);
        return name === 'sort' ? lt : ['List', INT];
      }
      case 'toFloat': this.expectType(args[0], INT, 'toFloat()'); return FLOAT;
      case 'round': case 'floor': case 'ceil': this.expectType(args[0], FLOAT, `${name}()`); return INT;
      case 'sqrt': this.expectType(args[0], FLOAT, 'sqrt()'); return FLOAT;
      case 'fixed': this.expectType(args[0], FLOAT, 'fixed()'); this.expectType(args[1], INT, 'the number of decimals'); return TEXT;
      case 'toIntOr': this.expectType(args[0], TEXT, 'toIntOr()'); this.expectType(args[1], INT, 'the fallback'); return INT;
      case 'toFloatOr': this.expectType(args[0], TEXT, 'toFloatOr()'); this.expectType(args[1], FLOAT, 'the fallback'); return FLOAT;
      case 'range': this.expectType(args[0], INT, 'range()'); return ['List', INT];
      case 'trim': case 'upper': case 'lower': this.expectType(args[0], TEXT, `${name}()`); return TEXT;
      case 'contains': this.expectType(args[0], TEXT, 'contains()'); this.expectType(args[1], TEXT, 'contains()'); return BOOL;
      case 'join': this.expectType(args[0], ['List', TEXT], 'join()'); this.expectType(args[1], TEXT, 'join()'); return TEXT;
      case 'rgb': args.forEach(a => this.expectType(a, INT, 'rgb()')); return COLOR;
    }
  }
  checkInput(t, placeholder, what = 'input', want = TEXT) {
    const eg = want === TEXT ? '""' : '0';
    if (t.kind === 'var') {
      const ty = this.states[t.name];
      if (ty === undefined) this.err(`'${t.name}' is not a state; declare it with: state ${t.name}: ${tname(want)} = ${eg}`, t);
      if (ty !== want) this.err(`${what} can only edit ${tname(want)} state, but '${t.name}' is ${tname(ty)}`, t);
    } else {
      if (t.kind !== 'field' && t.kind !== 'index') this.err(`${what} edits a ${tname(want)} state, or a place inside one like names[i]`, t);
      const ty = this.expr(t);
      if (ty !== want) this.err(`${what} can only edit ${tname(want)}, but this is ${tname(ty)}`, t);
      this.checkPath(t, t);
    }
    if (placeholder) this.expectType(placeholder, TEXT, 'a placeholder');
  }
  checkChoice(it, kind) {   // select and radio: a Text place, and the list of options
    this.checkInput(it.target, it.placeholder, kind);
    this.expectType(it.options, ['List', TEXT], `the options of a ${kind}`);
    this.checkMods(it.mods, kind, it);
  }
  checkbox(it) {
    this.expectType(it.e, BOOL, 'a checkbox');
    if (it.label) this.expectType(it.label, TEXT, 'a checkbox label');
    this.checkMods(it.mods, 'checkbox', it);
    if (it.action) { this.ret = null; this.block(it.action); }
    else if (!(it.e.kind === 'var' && it.e.name in this.states && !this.scopes.some(sc => it.e.name in sc)))
      this.err('a checkbox with no -> must name a Bool state, like: checkbox done "Finished"  (or add an action: checkbox flags[i] "x" -> ...)', it.e);
  }
  // ---- view
  view(items) {
    for (const it of items) {
      switch (it.kind) {
        case 'heading': case 'text': case 'bullet':
          this.expectType(it.e, TEXT, `'${it.kind}'`); this.checkMods(it.mods, it.kind, it); break;
        case 'para':
          this.checkMods(it.mods, 'para', it);
          for (const sp of it.spans) { this.expectType(sp.e, TEXT, "'span'"); this.checkMods(sp.mods, 'span', sp); }
          break;
        case 'button':
          this.expectType(it.label, TEXT, 'a button label'); this.checkMods(it.mods, 'button', it);
          this.ret = null; this.block(it.action); break;
        case 'checkbox': this.checkbox(it); break;
        case 'input': this.checkInput(it.target, it.placeholder); this.checkMods(it.mods, 'input', it); break;
        case 'every':
          this.expectType(it.ms, INT, 'the time between ticks (in milliseconds)');
          if (it.when) this.expectType(it.when, BOOL, "'every ... when'");
          this.ret = null; this.block(it.action); break;
        case 'textarea': this.checkInput(it.target, it.placeholder, 'textarea'); this.checkMods(it.mods, 'textarea', it); break;
        case 'slider':
          this.checkInput(it.target, null, 'slider', INT);
          this.expectType(it.lo, INT, 'the slider start'); this.expectType(it.hi, INT, 'the slider end');
          this.checkMods(it.mods, 'slider', it); break;
        case 'select': case 'radio': this.checkChoice(it, it.kind); break;
        case 'row': case 'column': this.checkMods(it.mods, it.kind, it); this.nest++; this.view(it.body); this.nest--; break;
        case 'grid':
          this.expectType(it.cols, INT, 'the number of grid columns'); this.checkMods(it.mods, 'grid', it);
          this.nest++; this.view(it.body); this.nest--; break;
        case 'modal': {
          if (this.nest) this.err('a modal must be directly in the view, not inside a row, a column or another modal', it);
          this.expectType(it.e, BOOL, 'a modal');
          this.checkMods(it.mods, 'modal', it);
          if (it.action) { this.ret = null; this.block(it.action); }
          else if (!(it.e.kind === 'var' && it.e.name in this.states && !this.scopes.some(sc => it.e.name in sc)))
            this.err('a modal with no -> must name a Bool state, like: modal open { ... }  (or add an action: modal step > 0 -> step = 0 { ... })', it.e);
          this.nest++; this.view(it.body); this.nest--; break;
        }
        case 'table': {
          this.checkMods(it.mods, 'table', it);
          const save = this.tbl; this.tbl = { cols: null, header: false };
          this.view(it.body); this.tbl = save; break;
        }
        case 'header': case 'cells': {
          const t = this.tbl;
          let n = 0;
          for (const c of it.cells) {
            if (c.kind === 'select') { this.checkInput(c.cond, c.e, 'select'); this.expectType(c.opts, ['List', TEXT], 'the options of a select'); }
            else if (c.kind === 'input') this.checkInput(c.cond, c.e);
            else if (c.kind === 'checkbox') this.checkbox({ e: c.cond, label: c.e, mods: [], action: c.action });
            else this.expectType(c.e, TEXT, c.kind === 'text' ? 'a table cell' : `a ${c.kind} label`);
            if (c.span < 1) this.err('a cell must span at least 1 column', { pos: c.spanPos });
            this.checkMods(c.mods, c.kind === 'text' ? 'cellrow' : c.kind, c);
            if (c.kind !== 'text') {
              if (c.target) this.expectType(c.target, TEXT, 'a link target');
              if (c.action) { this.ret = null; this.block(c.action); }
            }
            n += c.span;
          }
          if (it.kind === 'header') {
            if (t.header || t.cols !== null) this.err('a table can have one header, and it must come first', it);
            t.header = true;
          }
          if (t.cols === null) t.cols = n;
          else if (t.cols !== n) this.err(`this row has ${n} cell(s) but the table has ${t.cols} column(s)`, it);
          break;
        }
        case 'vif':
          this.expectType(it.cond, BOOL, 'an if condition');
          this.scoped(it.then); this.scoped(it.other); break;
        case 'vfor': {
          const ity = this.expr(it.iter);
          if (!isList(ity)) this.err(`can only loop over a List, not ${tname(ity)}`, it.iter);
          this.scopes.push({ [it.var]: ity[1], ['\0' + it.var]: true }); this.view(it.body); this.scopes.pop(); break;
        }
        case 'component': {
          const c = this.components[it.name];
          if (!c) this.err(`unknown component '${it.name}' (import it with: import component ${it.name} from "${it.name}.tern", or declare it in this file)`, it);
          const st = this.structs[c.propType];
          if (!st) this.err(`component '${it.name}' has an invalid props type`, it);
          const given = new Set();
          for (const [fname, val, fpos] of it.args) {
            const f = st.fields.find(x => x[0] === fname);
            if (!f) this.err(`${it.name} has no property '${fname}' (its properties are ${st.fields.map(x => x[0]).join(', ')})`, { pos: fpos });
            if (given.has(fname)) this.err(`property '${fname}' is given twice`, { pos: fpos });
            given.add(fname);
            this.expectType(val, f[1], `property '${fname}' of ${it.name}`);
          }
          const missing = st.fields.filter(f => !given.has(f[0]) && !f[3]);
          if (missing.length) this.err(`${it.name} needs ${missing.map(f => `${f[0]}: ${tname(f[1])}`).join(', ')}`, it);
          break;
        }
        case 'link':
          this.expectType(it.label, TEXT, 'a link label');
          if (it.target) this.expectType(it.target, TEXT, 'a link target');
          this.checkMods(it.mods, 'link', it);
          if (it.action) { this.ret = null; this.block(it.action); }
          break;
        case 'image': {
          this.expectType(it.e, TEXT, "'image'");
          this.checkMods(it.mods, 'image', it);
          const assets = this.opts.assets;
          if (assets && it.e.kind === 'str') {
            const v = it.e.v;
            if (!/^(https?:|data:)/.test(v) && !assets.includes(v))
              this.err(`no image called "${v}" (add one in the Images tab, or use a web address). Available: ${assets.join(', ') || 'none'}`, it.e);
          }
          break;
        }
      }
    }
  }
  scoped(items) { this.scopes.push({}); this.view(items); this.scopes.pop(); }
}

// ---------------------------------------------------------------- runtime
class Return { constructor(v) { this.value = v; } }

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
const deepEq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

class Page {
  constructor(src, opts) {
    this.prog = buildProgram(src, opts);
    new Checker(this.prog, opts).run();
    this.title = this.prog.title || 'Untitled';
    this.fns = {}; this.styles = {}; this.views = {}; this.structs = {}; this.methods = {}; this.components = {};
    for (const st of this.prog.structs) { this.structs[st.name] = st; for (const m of st.methods) this.methods[`${st.name}.${m.name}`] = m; }
    for (const c of (this.prog.components || [])) this.components[c.name] = c;
    for (const v of this.prog.views) this.views[v.name] = v;
    this.screen = this.prog.views[0] ? this.prog.views[0].name : 'home'; this.history = [];
    for (const f of this.prog.fns) this.fns[f.name] = f;
    for (const s of this.prog.styles) this.styles[s.name] = s;
    this.state = {};
    // `saved state` values the host kept from an earlier visit (opts.saved = { name: value }); a value of the
    // wrong type for the declaration is ignored, so changing a state's type never breaks the page
    this.savedNames = this.prog.states.filter(s => s.saved).map(s => s.name);
    for (const s of this.prog.states) {
      const keep = s.saved && opts && opts.saved && Object.prototype.hasOwnProperty.call(opts.saved, s.name) && this.fits(opts.saved[s.name], s.type);
      this.state[s.name] = keep ? JSON.parse(JSON.stringify(opts.saved[s.name])) : this.eval(s.init, [{}]);
    }
  }
  fits(v, ty) {
    if (ty === INT) return Number.isSafeInteger(v);
    if (ty === FLOAT) return typeof v === 'number' && Number.isFinite(v);
    if (ty === TEXT) return typeof v === 'string' && v.length <= 10000000;
    if (ty === BOOL) return typeof v === 'boolean';
    if (ty === COLOR) return typeof v === 'string' && /^#[0-9a-fA-F]{6}$/.test(v);
    if (ty === ALIGN) return typeof v === 'string' && Object.prototype.hasOwnProperty.call(ALIGNS, v);
    if (ty === FONT) return typeof v === 'string' && FONTS.includes(v);
    if (ty === ACTION) return false;
    if (isList(ty)) return Array.isArray(v) && v.length <= 1000000 && v.every(x => this.fits(x, ty[1]));
    const st = this.structs[ty];
    if (!st || v === null || typeof v !== 'object' || Array.isArray(v)) return false;
    const keys = Object.keys(v);
    const allowed = new Set(st.fields.map(f => f[0]));
    if (keys.some(k => !allowed.has(k))) return false;
    return st.fields.every(f => (Object.prototype.hasOwnProperty.call(v, f[0]) ? this.fits(v[f[0]], f[1]) : !!f[3]));
  }
  // the values of the `saved state`s as JSON text for the host to keep, or null if there are none or they
  // are over 64 KB (the host should then keep nothing and may tell the person)
  savedJSON() {
    if (!this.savedNames.length) return null;
    const out = {}; for (const n of this.savedNames) out[n] = this.state[n];
    const j = JSON.stringify(out);
    return j.length <= 65536 ? j : null;
  }
  get savedTooBig() { return this.savedNames.length > 0 && this.savedJSON() === null; }
  get screens() { return this.prog.views.map(v => v.name); }
  goto(name) {
    if (name === this.screen) return;
    this.history.push(this.screen); if (this.history.length > 50) this.history.shift();
    this.screen = name;
  }
  back() { if (this.history.length) this.screen = this.history.pop(); }
  rtErr(msg, node) { throw new TernError(msg, node.pos, 'runtime error'); }
  lookup(name, scopes) {
    for (let i = scopes.length - 1; i >= 0; i--) if (name in scopes[i]) return scopes[i][name];
    if (name in this.state) return this.state[name];
    return CONST_VALUES[name];
  }
  execBlock(stmts, scopes) {
    scopes.push({});
    try { for (const s of stmts) this.exec(s, scopes); } finally { scopes.pop(); }
  }
  exec(s, scopes) {
    switch (s.kind) {
      case 'let': scopes[scopes.length - 1][s.name] = this.eval(s.value, scopes); break;
      case 'assign': {
        const v = this.eval(s.value, scopes);
        for (let i = scopes.length - 1; i >= 0; i--) if (s.name in scopes[i]) { scopes[i][s.name] = v; return; }
        this.state[s.name] = v; break;
      }
      case 'if': this.execBlock(this.eval(s.cond, scopes) ? s.then : s.other, scopes); break;
      case 'for':
        for (const item of this.eval(s.iter, scopes).slice()) {
          scopes.push({ [s.var]: item });
          try { this.execBlock(s.body, scopes); } finally { scopes.pop(); }
        }
        break;
      case 'goto': this.goto(s.name); break;
      case 'back': this.back(); break;
      case 'return': throw new Return(s.value === null ? null : this.eval(s.value, scopes));
      case 'expr':
        if (s.value.kind === 'mcall' && s.value.writeBack) this.runMutating(s.value, scopes);
        else this.eval(s.value, scopes);
        break;
      case 'setpath': {
        const v = this.eval(s.value, scopes);
        this.writePath(this.locate(s.target, scopes), () => v, scopes);
        break;
      }
    }
  }
  // ---- changing a field or a method's self. Values are never shared, so a change builds a new value
  // for the whole path and stores it back in the variable the path starts from.
  locate(t, scopes) {                    // evaluate every list index once, giving { root, steps }
    if (t.kind === 'var') return { root: t.name, steps: [], node: t };
    const loc = this.locate(t.e, scopes);
    loc.steps.push(t.kind === 'field' ? { field: t.name } : { index: this.eval(t.idx, scopes), node: t });
    return loc;
  }
  readPath(loc, scopes) {
    let v = this.lookup(loc.root, scopes);
    for (const st of loc.steps) {
      if ('field' in st) { v = v[st.field]; continue; }
      if (!(st.index >= 0 && st.index < v.length)) this.rtErr(`index ${st.index} is outside the list (length ${v.length})`, st.node);
      v = v[st.index];
    }
    return v;
  }
  writePath(loc, f, scopes) {
    const apply = (cur, k) => {
      if (k === loc.steps.length) return f(cur);
      const st = loc.steps[k];
      if ('field' in st) return Object.assign({}, cur, { [st.field]: apply(cur[st.field], k + 1) });
      if (!(st.index >= 0 && st.index < cur.length)) this.rtErr(`index ${st.index} is outside the list (length ${cur.length})`, st.node);
      const copy = cur.slice(); copy[st.index] = apply(cur[st.index], k + 1); return copy;
    };
    let holder = this.state;
    for (let i = scopes.length - 1; i >= 0; i--) if (loc.root in scopes[i]) { holder = scopes[i]; break; }
    holder[loc.root] = apply(holder[loc.root], 0);
  }
  runMutating(e, scopes) {
    const loc = this.locate(e.recv, scopes);
    const cur = this.readPath(loc, scopes);
    const args = e.args.map(a => this.eval(a, scopes));
    const out = this.runBody(this.methods[e.method], { self: cur }, args, e, e.method);
    this.writePath(loc, () => out.vars.self, scopes);
  }
  eval(e, scopes) {
    switch (e.kind) {
      case 'int': case 'str': case 'bool': case 'color': case 'float': return e.v;
      case 'var': return this.lookup(e.name, scopes);
      case 'list': return e.items.map(i => this.eval(i, scopes));
      case 'un': { const v = this.eval(e.e, scopes); return e.op === '!' ? !v : -v; }
      case 'index': {
        const lst = this.eval(e.e, scopes), i = this.eval(e.idx, scopes);
        if (!(i >= 0 && i < lst.length)) this.rtErr(`index ${i} is outside the list (length ${lst.length})`, e);
        return lst[i];
      }
      case 'bin': return this.binop(e, scopes);
      case 'action':
        return { __action: { stmts: e.body, scopes: scopes.map(s => ({ ...s })) } };
      case 'call': {
        if (!(e.name in this.fns) && !(e.name in BUILTINS)) {
          const v = this.lookup(e.name, scopes);
          if (v && v.__action) { this.execBlock(v.__action.stmts, v.__action.scopes.map(s => ({ ...s }))); return null; }
        }
        return this.call(e, scopes);
      }
      case 'mcall': {
        if (e.actionField) {
          const recv = this.eval(e.recv, scopes);
          const av = recv && recv[e.name];
          if (av && av.__action) this.execBlock(av.__action.stmts, av.__action.scopes.map(s => ({ ...s })));
          return null;
        }
        const self = this.eval(e.recv, scopes);
        const args = e.args.map(a => this.eval(a, scopes));
        return this.runBody(this.methods[e.method], { self }, args, e, e.method).ret;
      }
      case 'construct': {
        const vals = {};
        for (const [n, v] of e.fields) vals[n] = this.eval(v, scopes);
        const st = this.structs[e.name];
        const o = {};
        if (st) {
          for (const f of st.fields) o[f[0]] = Object.prototype.hasOwnProperty.call(vals, f[0]) ? vals[f[0]] : this.eval(f[3], scopes);
        } else {
          for (const [n, v] of e.fields) o[n] = vals[n];
        }
        return o;
      }
      case 'field': return this.eval(e.e, scopes)[e.name];
      case 'with': {
        const o = Object.assign({}, this.eval(e.e, scopes));
        for (const [fname, val] of e.updates) o[fname] = this.eval(val, scopes);
        return o;
      }
    }
  }
  binop(e, scopes) {
    const op = e.op;
    if (op === '&&') return this.eval(e.l, scopes) && this.eval(e.r, scopes);
    if (op === '||') return this.eval(e.l, scopes) || this.eval(e.r, scopes);
    const a = this.eval(e.l, scopes), b = this.eval(e.r, scopes);
    switch (op) {
      case '+': return Array.isArray(a) ? a.concat(b) : a + b;
      case '-': return a - b;
      case '*': return a * b;
      case '/': case '%':
        if (b === 0) this.rtErr('division by zero', e);
        if (op === '/') return e.opType === FLOAT ? a / b : Math.floor(a / b);
        return ((a % b) + b) % b;
      case '==': return deepEq(a, b);
      case '!=': return !deepEq(a, b);
      case '<': return a < b; case '>': return a > b; case '<=': return a <= b; case '>=': return a >= b;
    }
  }
  // runs a function or method body; `vars` holds `self` for methods. Returns the result and the final variables.
  runBody(f, vars, args, e, name) {
    const frame = [{}, Object.assign(vars, Object.fromEntries(f.params.map((p, i) => [p[0], args[i]])))];
    try { this.execBlock(f.body, frame); }
    catch (r) {
      if (r instanceof Return) return { ret: r.value, vars: frame[1] };
      if (r instanceof RangeError) this.rtErr(`${name}() recursed too deeply`, e);
      throw r;
    }
    return { ret: null, vars: frame[1] };
  }
  call(e, scopes) {
    const args = e.args.map(a => this.eval(a, scopes));
    const name = e.name;
    if (name in this.fns) {
      return this.runBody(this.fns[name], {}, args, e, name).ret;
    }
    switch (name) {
      case 'toText':
        if (typeof args[0] === 'boolean') return args[0] ? 'true' : 'false';
        if (e.argType === FLOAT) return Number.isInteger(args[0]) ? args[0].toFixed(1) : String(+args[0].toPrecision(12));
        return String(args[0]);
      case 'toFloat': return args[0];
      case 'round': return Math.round(args[0]);
      case 'floor': return Math.floor(args[0]);
      case 'ceil': return Math.ceil(args[0]);
      case 'sqrt':
        if (args[0] < 0) this.rtErr('cannot take the square root of a negative number', e);
        return Math.sqrt(args[0]);
      case 'fixed': return args[0].toFixed(clamp(args[1], 0, 12));
      case 'toIntOr': return /^\s*-?\d+\s*$/.test(args[0]) ? parseInt(args[0], 10) : args[1];
      case 'toFloatOr': return /^\s*-?(\d+\.?\d*|\.\d+)\s*$/.test(args[0]) ? parseFloat(args[0]) : args[1];
      case 'len': return args[0].length;
      case 'append': return args[0].concat([args[1]]);
      case 'removeAt':
        if (!(args[1] >= 0 && args[1] < args[0].length)) this.rtErr(`index ${args[1]} is outside the list (length ${args[0].length})`, e);
        return args[0].slice(0, args[1]).concat(args[0].slice(args[1] + 1));
      case 'setAt': {
        if (!(args[1] >= 0 && args[1] < args[0].length)) this.rtErr(`index ${args[1]} is outside the list (length ${args[0].length})`, e);
        const copy = args[0].slice(); copy[args[1]] = args[2]; return copy;
      }
      case 'slice': {
        const n = args[0].length, a = clamp(args[1], 0, n), b = clamp(args[2], 0, n);
        return b > a ? args[0].slice(a, b) : [];
      }
      case 'reverse': return args[0].slice().reverse();
      case 'sort': case 'sortOrder': {
        const xs = args[0], cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0);   // Text compares by UTF-16 code unit
        const idx = xs.map((_, i) => i).sort((i, j) => cmp(xs[i], xs[j]) || i - j);
        return name === 'sort' ? idx.map(i => xs[i]) : idx;
      }
      case 'range': return Array.from({ length: clamp(args[0], 0, 10000) }, (_, i) => i);
      case 'trim': return args[0].trim();
      case 'upper': return args[0].toUpperCase();
      case 'lower': return args[0].toLowerCase();
      case 'contains': return args[0].includes(args[1]);
      case 'join': return args[0].join(args[1]);
      case 'rgb': return '#' + args.map(v => clamp(v, 0, 255).toString(16).padStart(2, '0')).join('');
    }
  }

  // ---- style resolution
  applyMod(out, m, scopes) {
    if (FLAGS.has(m.name)) out[m.name] = m.when === null ? true : !!this.eval(m.when, scopes);
    else if (m.name === 'size') out.size = clamp(this.eval(m.value, scopes), 6, 96);
    else if (m.name === 'padding' || m.name === 'gap' || m.name === 'margin') out[m.name] = clamp(this.eval(m.value, scopes), 0, 64);
    else if (m.name === 'grow') out.grow = clamp(this.eval(m.value, scopes), 0, 12);
    else if (m.name === 'radius') out.radius = clamp(this.eval(m.value, scopes), 0, 999);
    else if (m.name === 'width' || m.name === 'height' || m.name === 'maxwidth' || m.name === 'minwidth') out[m.name] = clamp(this.eval(m.value, scopes), 1, 2000);
    else out[m.name] = this.eval(m.value, scopes);
  }
  resolve(mods, kind, scopes) {
    const out = {}, allowed = ALLOWED[kind];
    for (const m of mods) {
      if (m.name === 'style') {
        for (const [n] of m.value) for (const sm of this.styles[n].mods) if (allowed.has(sm.name)) this.applyMod(out, sm, [{}]);
      } else this.applyMod(out, m, scopes);
    }
    return out;
  }

  inputNode(target, name, placeholder, scopes, mods = [], kind = 'input') {
    const snap = scopes.map(s => ({ ...s }));
    return this.lock({ t: 'input', name, value: this.readPath(this.locate(target, scopes), scopes),
      placeholder: placeholder ? this.eval(placeholder, scopes) : '',
      style: this.resolve(mods, kind, scopes),
      set: v => { this.writePath(this.locate(target, snap), () => v, snap); } });
  }
  // a disabled control does nothing when it is tapped or edited, whatever the host does
  lock(n) {
    if (n.style && n.style.disabled) { if (n.click) n.click = () => {}; if (n.set) n.set = () => {}; }
    return n;
  }
  checkboxNode(it, scopes) {
    const snap = scopes.map(s => ({ ...s }));
    const name = it.action ? null : it.e.name;
    return this.lock({ t: 'checkbox', label: it.label ? this.eval(it.label, scopes) : '', checked: !!this.eval(it.e, scopes),
      style: this.resolve(it.mods, 'checkbox', scopes),
      click: it.action ? () => this.execBlock(it.action, snap) : () => { this.state[name] = !this.state[name]; } });
  }
  // ---- render tree
  render() { this.timerSeq = 0; this.timers = []; const out = []; this.view(this.views[this.screen].body, [{}], out); return out; }
  // every <ms> ... draws nothing: it adds a timer to page.timers (after each render()), which the host runs on its
  // schedule while it stays in the list. At least 100 ms apart, at most 4 timers at once, and a timer that fails 3 times in a row stops.
  timerNode(it, scopes) {
    if (it.when && !this.eval(it.when, scopes)) return null;
    const n = this.timerSeq++;
    if (n >= 4) return null;
    const key = `${it.pos[0]}:${it.pos[1]}#${n}`;
    this.faults = this.faults || {};
    if ((this.faults[key] || 0) >= 3) return null;
    const snap = scopes.map(s => ({ ...s }));
    return { key, ms: clamp(this.eval(it.ms, scopes), 100, 3600000),
      tick: () => {
        try { this.execBlock(it.action, snap); this.faults[key] = 0; }
        catch (e) {
          this.faults[key] = (this.faults[key] || 0) + 1;
          if (e instanceof TernError && this.faults[key] >= 3) e.msg += ' (this timer has stopped after 3 errors in a row)';
          throw e;
        }
      } };
  }
  view(items, scopes, out) {
    for (const it of items) {
      switch (it.kind) {
        case 'heading': case 'text': case 'bullet':
          out.push({ t: it.kind, text: this.eval(it.e, scopes), style: this.resolve(it.mods, it.kind, scopes) }); break;
        case 'para': {
          const base = this.resolve(it.mods, 'para', scopes);
          const inherit = { ...base }; delete inherit.align;
          out.push({
            t: 'para', style: base,
            spans: it.spans.map(sp => ({ text: this.eval(sp.e, scopes), style: { ...inherit, ...this.resolve(sp.mods, 'span', scopes) } })),
          });
          break;
        }
        case 'button': {
          const snap = scopes.map(s => ({ ...s }));
          out.push(this.lock({ t: 'button', label: this.eval(it.label, scopes), style: this.resolve(it.mods, 'button', scopes),
            click: () => this.execBlock(it.action, snap) }));
          break;
        }
        case 'checkbox': {
          out.push(this.checkboxNode(it, scopes)); break;
        }
        case 'grid': {
          const kids = []; this.view(it.body, scopes, kids);
          out.push({ t: 'grid', cols: clamp(this.eval(it.cols, scopes), 1, 12), children: kids, style: this.resolve(it.mods, 'grid', scopes) }); break;
        }
        case 'modal': {
          if (!this.eval(it.e, scopes)) break;   // a closed modal draws nothing
          const snap = scopes.map(s => ({ ...s })), kids = [];
          this.view(it.body, scopes, kids);
          out.push({ t: 'modal', children: kids, style: this.resolve(it.mods, 'modal', scopes),
            close: it.action ? () => this.execBlock(it.action, snap) : () => { this.state[it.e.name] = false; } });
          break;
        }
        case 'input': out.push(this.inputNode(it.target, it.name, it.placeholder, scopes, it.mods, 'input')); break;
        case 'every': { const n = this.timerNode(it, scopes); if (n) this.timers.push(n); break; }
        case 'textarea': { const n = this.inputNode(it.target, '', it.placeholder, scopes, it.mods, 'textarea'); n.t = 'textarea'; out.push(n); break; }
        case 'slider': {
          const n = this.inputNode(it.target, '', null, scopes, it.mods, 'slider');
          n.t = 'slider'; n.lo = this.eval(it.lo, scopes); n.hi = this.eval(it.hi, scopes);
          if (n.hi < n.lo) this.rtErr(`this slider ends (${n.hi}) before it starts (${n.lo})`, it);
          n.value = clamp(n.value, n.lo, n.hi);
          out.push(n); break;
        }
        case 'select': case 'radio': {
          const n = this.inputNode(it.target, '', it.placeholder, scopes, it.mods, it.kind);
          n.t = it.kind; n.options = this.eval(it.options, scopes).slice();
          out.push(n); break;
        }
        case 'row': case 'column': {
          const kids = []; this.view(it.body, scopes, kids);
          out.push({ t: it.kind, children: kids, style: this.resolve(it.mods, it.kind, scopes) }); break;
        }
        case 'table': {
          const kids = []; this.view(it.body, scopes, kids);
          const h = kids.find(k => k.t === 'header');
          const rows = kids.filter(k => k.t === 'cells');
          out.push({ t: 'table', resizable: it.resizable, style: this.resolve(it.mods, 'table', scopes), header: h ? h.cells : null, rows: rows.map(k => k.cells),
            hrow: h ? h.row : null, body: rows.map(k => k.row) });
          break;
        }
        case 'header': case 'cells': {
          const snap = scopes.map(s => ({ ...s })), cells = [], flat = [];
          for (const c of it.cells) {
            const text = this.eval(c.e, scopes);
            const cell = { text, span: c.span, kind: c.kind };
            if (c.kind === 'select') {
              const sel = this.inputNode(c.cond, '', c.e, scopes);
              cell.text = sel.value; cell.placeholder = sel.placeholder; cell.set = sel.set; cell.options = this.eval(c.opts, scopes).slice(); cells.push(cell);
              flat.push('[select: ' + (sel.value || sel.placeholder) + ']'); for (let k = 1; k < c.span; k++) flat.push('');
              continue;
            }
            if (c.kind === 'input') {
              const inp = this.inputNode(c.cond, '', c.e, scopes);
              cell.text = inp.value; cell.placeholder = inp.placeholder; cell.set = inp.set; cells.push(cell);
              flat.push('[_' + inp.value + '_]'); for (let k = 1; k < c.span; k++) flat.push('');
              continue;
            }
            if (c.kind === 'checkbox') {
              const cb = this.checkboxNode({ e: c.cond, label: c.e, mods: c.mods, action: c.action }, scopes);
              cell.checked = cb.checked; cell.click = cb.click; cell.style = cb.style; cells.push(cell);
              flat.push((cb.checked ? '[x] ' : '[ ] ') + text); for (let k = 1; k < c.span; k++) flat.push('');
              continue;
            }
            cell.style = this.resolve(c.mods, c.kind === 'text' ? 'cellrow' : c.kind, scopes);
            if (c.kind !== 'text') {
              cell.target = c.target ? this.eval(c.target, scopes) : null;
              cell.click = c.action ? () => this.execBlock(c.action, snap) : null;
              this.lock(cell);
            }
            cells.push(cell);
            flat.push(text); for (let k = 1; k < c.span; k++) flat.push('');
          }
          out.push({ t: it.kind, cells: flat, row: { cells } });
          break;
        }
        case 'vif': this.view(this.eval(it.cond, scopes) ? it.then : it.other, scopes, out); break;
        case 'vfor':
          for (const item of this.eval(it.iter, scopes).slice()) {
            scopes.push({ [it.var]: item });
            try { this.view(it.body, scopes, out); } finally { scopes.pop(); }
          }
          break;
        case 'component': {
          const c = this.components[it.name];
          if (c) {
            const props = {}, given = new Set();
            for (const [n, v] of it.args) { props[n] = this.eval(v, scopes); given.add(n); }
            const st = this.structs[c.propType];
            if (st) for (const f of st.fields) if (!given.has(f[0]) && f[3]) props[f[0]] = this.eval(f[3], scopes);
            scopes.push({ [c.propName]: props });
            try { this.view(c.body, scopes, out); } finally { scopes.pop(); }
          }
          break;
        }
        case 'link': {
          const snap = scopes.map(s => ({ ...s }));
          out.push({ t: 'link', text: this.eval(it.label, scopes), target: it.target ? this.eval(it.target, scopes) : null,
            click: it.action ? () => this.execBlock(it.action, snap) : null,
            style: this.resolve(it.mods, 'link', scopes) });
          break;
        }
        case 'image': {
          const st = this.resolve(it.mods, 'image', scopes);
          const alt = st.alt || ''; delete st.alt;
          out.push({ t: 'image', src: this.eval(it.e, scopes), alt, style: st });
          break;
        }
        case 'divider': out.push({ t: 'divider' }); break;
      }
    }
  }
}

const load = (src, opts) => new Page(src, opts);

// plain-text view, used by tests
function renderText(nodes, indent = 0) {
  const pad = '  '.repeat(indent), lines = [];
  const mark = (txt, st) => { let t = txt; if (st.bold) t = `**${t}**`; if (st.italic) t = `_${t}_`; return t; };
  for (const n of nodes) {
    switch (n.t) {
      case 'heading': lines.push(pad + n.text.toUpperCase()); break;
      case 'text': lines.push(pad + mark(n.text, n.style)); break;
      case 'bullet': lines.push(`${pad}* ${mark(n.text, n.style)}`); break;
      case 'para': lines.push(pad + n.spans.map(s => mark(s.text, s.style)).join('')); break;
      case 'button': lines.push(`${pad}[ ${n.label} ]`); break;
      case 'grid': lines.push(`${pad}<grid ${n.cols}>`, ...renderText(n.children, indent + 1)); break;
      case 'modal': lines.push(pad + '[modal]', ...renderText(n.children, indent + 1), pad + '[/modal]'); break;
      case 'textarea': lines.push(`${pad}[textarea: ${(n.value || n.placeholder).split('\n')[0]}]`); break;
      case 'slider': lines.push(`${pad}[slider: ${n.value} in ${n.lo}..${n.hi}]`); break;
      case 'select': lines.push(`${pad}[select: ${n.value || n.placeholder}]`); break;
      case 'radio': for (const o of n.options) lines.push(`${pad}(${o === n.value ? 'x' : ' '}) ${o}`); break;
      case 'checkbox': lines.push(`${pad}[${n.checked ? 'x' : ' '}] ${n.label}`); break;
      case 'input': lines.push(`${pad}[_${n.value || (n.placeholder ? `(${n.placeholder})` : '')}_]`); break;
      case 'link': lines.push(`${pad}${n.text} -> ${n.target || '(action)'}`); break;
      case 'image': lines.push(`${pad}[image: ${n.src}]`); break;
      case 'divider': lines.push(pad + '-'.repeat(40)); break;
      case 'table': {
        const rows = (n.header ? [n.header] : []).concat(n.rows);
        const widths = rows[0] ? rows[0].map((_, c) => Math.max(...rows.map(r => r[c].length))) : [];
        rows.forEach((r, i) => {
          lines.push(pad + '| ' + r.map((c, j) => c.padEnd(widths[j])).join(' | ') + ' |');
          if (i === 0 && n.header) lines.push(pad + '|' + widths.map(w => '-'.repeat(w + 2)).join('|') + '|');
        });
        break;
      }
      case 'row': case 'column':
        lines.push(`${pad}<${n.t}>`); lines.push(...renderText(n.children, indent + 1)); break;
    }
  }
  return lines;
}

const api = { TernError, load, parse, renderText, COLORS, FONTS, version: '0.3' };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
else root.Tern = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
